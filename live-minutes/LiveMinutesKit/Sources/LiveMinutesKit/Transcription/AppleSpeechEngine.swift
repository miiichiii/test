import AVFAudio
import CoreMedia
import Foundation
import os
import Speech

/// `SpeechAnalyzer` + `SpeechTranscriber` による端末内の文字起こし（DESIGN.md §4.2）。
///
/// `SpeechAnalyzer` は一度 finish すると再利用できないため、`start(source:)` のたびに
/// `SpeechTranscriber` と `SpeechAnalyzer` を作り直す。`prepare` で保持するのはロケールと入力形式だけ。
/// 認識言語は `prepare(locale:progress:)` で渡す（設定で変えたら、次のセッションの開始前に呼び直す）。
public actor AppleSpeechEngine: TranscriptionEngine {
    private enum State {
        case idle, starting, running, stopping
    }

    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?

    private var state: State = .idle
    private var analyzer: SpeechAnalyzer?
    private var source: (any AudioSource)?
    private var eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    /// 開始処理の途中（starting）で結果のストリームが終わった場合の理由。開始処理の最後で確かめる。
    private var failureWhileStarting: (any Error)?

    /// 停止時に、最終確定と結果の読み取りを待つ上限。
    private static let stopTimeout: Duration = .seconds(10)
    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Transcription")

    /// prepare で決めた入力形式（テスト用）。
    var preparedAudioFormat: AVAudioFormat? { analyzerFormat }

    /// 音声認識に渡す用語（固有名詞や専門用語。Phase 6）。開始のたびに読む
    private let contextualStrings: @Sendable () async -> [String]

    /// - Parameter contextualStrings: 登録した用語を返す。`AnalysisContext.contextualStrings[.general]` として渡す
    ///   （どれだけ反映されるかは DESIGN.md §8 #7 のとおり未確認）
    public init(contextualStrings: @escaping @Sendable () async -> [String] = { [] }) {
        self.contextualStrings = contextualStrings
    }

    /// この Mac で端末内の音声認識が対応しているロケール（BCP 47 の識別子、並べ替え済み）。設定画面の一覧に使う。
    public static func supportedLocaleIdentifiers() async -> [String] {
        let identifiers = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        return Array(Set(identifiers)).sorted()
    }

    // MARK: - prepare（手順1〜4）

    public func prepare(locale requestedLocale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        // 実行中に認識言語を変えない（次の start から反映する）。
        guard state == .idle else { throw TranscriptionError.alreadyRunning }
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.transcriberUnavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(requestedLocale.identifier(.bcp47))
        }
        let transcriber = Self.makeTranscriber(locale: supported)

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let requestProgress = request.progress
                // Progress は Sendable。KVO の代わりに一定間隔で読む。
                let reporter = Task {
                    while !Task.isCancelled {
                        progress(requestProgress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { reporter.cancel() }
                try await request.downloadAndInstall()
                progress(1)
            }
        } catch {
            throw TranscriptionError.modelDownloadFailed(error.localizedDescription)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }
        locale = supported
        analyzerFormat = format
    }

    // MARK: - start（手順5〜7）

    public func start(source: any AudioSource) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        // actor は await で再入するので、最初の await より前に状態を変える。
        guard state == .idle else { throw TranscriptionError.alreadyRunning }
        guard let locale, let analyzerFormat else { throw TranscriptionError.notPrepared }
        state = .starting
        failureWhileStarting = nil

        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: TranscriptEvent.self)

        do {
            // モデルを先に読み込み、マイクの音声が溜まる前に準備を終える。
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            await applyContextualStrings(to: analyzer)
            try await analyzer.start(inputSequence: inputs)
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            state = .idle
            throw error
        }

        self.analyzer = analyzer
        self.eventContinuation = eventContinuation
        let results = transcriber.results
        resultsTask = Task { [weak self] in
            do {
                var lastEnd: TimeInterval = 0
                for try await result in results {
                    guard let event = TranscriptEventMapper.event(
                        text: String(result.text.characters),
                        isFinal: result.isFinal,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        lastEnd: lastEnd
                    ) else { continue }
                    if case .final(let segment) = event {
                        lastEnd = segment.end
                    }
                    eventContinuation.yield(event)
                }
                await self?.resultsDidEnd(error: nil)
            } catch {
                await self?.resultsDidEnd(error: error)
            }
        }

        let chunks: AsyncStream<AudioChunk>
        do {
            chunks = try await source.start(outputFormat: analyzerFormat)
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            eventContinuation.finish()
            reset()
            throw error
        }

        // ソースを開始するまでの間に認識が終わってしまった場合は、ソースを止めて失敗にする。
        if let failure = failureWhileStarting {
            await source.stop()
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            eventContinuation.finish()
            reset()
            throw failure
        }

        self.source = source
        // 入力の continuation を閉じるのはこの Task だけにする（ソースのストリームが終わったとき）。
        feedTask = Task {
            for await chunk in chunks {
                inputContinuation.yield(AnalyzerInput(buffer: chunk.buffer))
            }
            inputContinuation.finish()
        }
        state = .running
        return events
    }

    // MARK: - stop（手順8）

    public func stop() async {
        guard state == .running else { return }
        state = .stopping

        await source?.stop()
        await feedTask?.value

        // 最終確定や結果の読み取りが終わらない場合に備えて、両方を覆う上限を設ける。
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        let watchdog = Task {
            try await Task.sleep(for: Self.stopTimeout)
            Self.logger.error("停止処理が終わらないため打ち切る")
            resultsTask?.cancel()
            await analyzer?.cancelAndFinishNow()
        }

        if let analyzer {
            do {
                // 呼ばないと、最後の未確定分が確定されずに失われる。
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Self.logger.error("最終確定に失敗: \(String(describing: error), privacy: .public)")
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value
        watchdog.cancel()

        eventContinuation?.finish()
        reset()
    }

    // MARK: - 内部

    /// 結果のストリームが終わったとき（エラーの有無によらず）に必ず呼ばれる。
    /// 停止操作による終了なら何もしない。それ以外は失敗として後始末する（マイクを点けたままにしない）。
    private func resultsDidEnd(error: (any Error)?) async {
        let reason = error ?? TranscriptionError.recognitionEnded
        switch state {
        case .starting:
            failureWhileStarting = reason
        case .running:
            await fail(reason)
        case .idle, .stopping:
            break
        }
    }

    /// 録音中に認識が失敗した場合。マイクを止め、ストリームをエラーで終える。
    private func fail(_ error: any Error) async {
        guard state == .running else { return }
        state = .stopping
        Self.logger.error("認識が失敗したため停止する: \(String(describing: error), privacy: .public)")

        await source?.stop()
        await feedTask?.value
        await analyzer?.cancelAndFinishNow()
        eventContinuation?.finish(throwing: error)
        reset()
    }

    private func reset() {
        analyzer = nil
        source = nil
        eventContinuation = nil
        feedTask = nil
        resultsTask = nil
        failureWhileStarting = nil
        state = .idle
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// 登録した用語を、音声認識の文脈として渡す。失敗しても認識は続ける（用語なしで認識するだけなので）。
    private func applyContextualStrings(to analyzer: SpeechAnalyzer) async {
        let terms = await contextualStrings()
        guard !terms.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        do {
            try await analyzer.setContext(context)
        } catch {
            Self.logger.notice("用語を音声認識に渡せなかった（\(terms.count) 件）: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

}
