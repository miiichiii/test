import AVFAudio
import Foundation
import os

/// Whisper の書き起こし1回分。テストでは偽物に差し替える（DESIGN.md §4.2「Whisper（ローカル）での書き起こし」）。
public protocol WhisperTranscriber: Sendable {
    /// 16kHz・モノラルの音声を書き起こす。
    /// - Parameter language: Whisper の言語コード（`ja` など）
    func transcribe(_ samples: [Float], language: String) async throws -> String
}

/// Whisper（ローカル）での書き起こし。`TranscriptionEngine` の2つめの実装。
///
/// - 音声は `WhisperChunker` で無音か長さの上限で区切り、区切りごとに書き起こして確定（`.final`）として流す
/// - 区切りの途中は約2秒ごとに、書き起こしが空いていれば途中結果（`.volatile`）を出す（確定を優先する）
/// - 書き起こしは1本の Task で順に行う（順序を保つため）
/// - `stop()` で残りの音声を最後の区切りとして書き起こしてから、ストリームを終える
public actor WhisperLocalEngine: TranscriptionEngine {
    /// 今の設定のモデル名を返す（次に開始する会議から反映するため、開始のたびに読む）
    public typealias ModelName = @Sendable () async -> String
    /// モデルを読み込む。モデルがなければ `TranscriptionError.whisperModelMissing` を投げる
    public typealias Loader = @Sendable (_ modelName: String) async throws -> any WhisperTranscriber

    private enum JobKind {
        case final(start: TimeInterval, end: TimeInterval)
        case partial
    }

    private struct Job {
        let samples: [Float]
        let kind: JobKind
    }

    static let partialInterval: TimeInterval = 2

    private let modelName: ModelName
    private let load: Loader
    private var transcriber: (any WhisperTranscriber)?
    private var loadedModelName: String?
    private var language = "ja"

    private var isRunning = false
    private var source: (any AudioSource)?
    private var eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var jobContinuation: AsyncStream<Job>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var chunker = WhisperChunker()
    /// 書き起こし待ちと書き起こし中の件数（途中結果は、これが0のときだけ頼む）
    private var pendingJobs = 0
    /// 最後に途中結果を頼んだ時点の、区切りの途中の音声の長さ
    private var lastPartialDuration: TimeInterval = 0

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Whisper")

    public init(modelName: @escaping ModelName, load: @escaping Loader) {
        self.modelName = modelName
        self.load = load
    }

    /// Whisper に渡す形式（16kHz・モノラル・Float32）
    static var inputFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    /// ロケール（`ja-JP` など）から Whisper の言語コード（`ja`）を作る
    static func languageCode(for locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? "ja"
    }

    public func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        language = Self.languageCode(for: locale)
        progress(0)
        try await ensureLoaded()
        progress(1)
    }

    /// 設定のモデルが読み込んだものと違えば（またはまだなら）読み込む。
    private func ensureLoaded() async throws {
        let name = await modelName()
        if transcriber != nil, loadedModelName == name { return }
        transcriber = nil
        loadedModelName = nil
        let loaded = try await load(name)
        transcriber = loaded
        loadedModelName = name
    }

    public func start(source: any AudioSource) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        guard !isRunning else { throw TranscriptionError.alreadyRunning }
        try await ensureLoaded()
        guard let transcriber else { throw TranscriptionError.notPrepared }
        guard let format = Self.inputFormat else { throw TranscriptionError.noCompatibleAudioFormat }

        let chunks = try await source.start(outputFormat: format)
        let (events, eventContinuation) = AsyncThrowingStream.makeStream(of: TranscriptEvent.self)
        let (jobs, jobContinuation) = AsyncStream.makeStream(of: Job.self)
        self.source = source
        self.eventContinuation = eventContinuation
        self.jobContinuation = jobContinuation
        chunker = WhisperChunker()
        pendingJobs = 0
        lastPartialDuration = 0
        isRunning = true

        let language = self.language
        workerTask = Task { [weak self] in
            for await job in jobs {
                do {
                    let text = try await transcriber.transcribe(job.samples, language: language)
                    await self?.deliver(text, for: job)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.fail(error)
                    return
                }
            }
            await self?.workerDidDrain()
        }
        readerTask = Task { [weak self] in
            for await chunk in chunks {
                await self?.feed(chunk)
            }
            await self?.feedDidEnd()
        }
        return events
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        // マイクを止めると音声のストリームが終わり、残りを最後の区切りとして頼んでから、書き起こしの列を閉じる。
        await source?.stop()
        await readerTask?.value
        await workerTask?.value
        eventContinuation?.finish()
        reset()
    }

    // MARK: - 内部

    private func feed(_ chunk: AudioChunk) {
        guard let samples = Self.samples(of: chunk.buffer) else { return }
        for completed in chunker.append(samples) {
            enqueue(Job(samples: completed.samples, kind: .final(start: completed.start, end: completed.end)))
            lastPartialDuration = 0
        }
        // 区切りの途中は、書き起こしが空いているときだけ、約2秒ごとに途中結果を頼む。
        if chunker.isInSpeech, pendingJobs == 0,
           chunker.bufferedDuration - lastPartialDuration >= Self.partialInterval {
            lastPartialDuration = chunker.bufferedDuration
            enqueue(Job(samples: chunker.buffer, kind: .partial))
        }
    }

    private func feedDidEnd() {
        if let last = chunker.flush() {
            enqueue(Job(samples: last.samples, kind: .final(start: last.start, end: last.end)))
        }
        jobContinuation?.finish()
    }

    private func enqueue(_ job: Job) {
        pendingJobs += 1
        jobContinuation?.yield(job)
    }

    private func deliver(_ text: String, for job: Job) {
        pendingJobs = max(pendingJobs - 1, 0)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch job.kind {
        case .partial:
            guard !trimmed.isEmpty else { return }
            eventContinuation?.yield(.volatile(trimmed))
        case .final(let start, let end):
            // 空の確定は出さない（TranscriptEventMapper と同じ扱い）。
            guard !trimmed.isEmpty else {
                eventContinuation?.yield(.volatile(""))
                return
            }
            eventContinuation?.yield(.final(TranscriptSegment(start: start, end: end, text: trimmed)))
        }
    }

    /// 書き起こしの列を最後まで処理した。停止操作によらずに音声が終わった場合は、ここでストリームを終える
    /// （停止操作の場合は `stop()` が終える）。
    private func workerDidDrain() {
        guard isRunning else { return }
        isRunning = false
        eventContinuation?.finish()
        reset()
    }

    /// 書き起こしに失敗した。マイクを止め、ストリームをエラーで終える。
    private func fail(_ error: any Error) async {
        guard isRunning else { return }
        isRunning = false
        Self.logger.error("Whisper の書き起こしに失敗したため停止する: \(String(describing: type(of: error)), privacy: .public)")
        jobContinuation?.finish()
        readerTask?.cancel()
        await source?.stop()
        let reported = (error as? TranscriptionError) ?? .whisperFailed(String(describing: type(of: error)))
        eventContinuation?.finish(throwing: reported)
        reset()
    }

    private func reset() {
        source = nil
        eventContinuation = nil
        jobContinuation = nil
        readerTask = nil
        workerTask = nil
        chunker = WhisperChunker()
        pendingJobs = 0
        lastPartialDuration = 0
    }

    /// バッファの1チャンネル目を Float の配列にする（ソースが 16kHz・モノラル・Float32 に変換済み）。
    static func samples(of buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
