import AVFAudio
import Foundation
import os

/// マイク入力（AVAudioEngine の inputNode に付けた tap）による `AudioSource`。
///
/// - tap のコールバックでは「変換」「レベル計算」「ストリームへの受け渡し」だけを行う（`TapProcessor`）
/// - 入力デバイスが変わると（`AVAudioEngineConfigurationChange`）、AVAudioEngine ごと作り直して録音を続ける。
///   音声のストリームは切らない
public actor MicrophoneSource: AudioSource {
    public nonisolated let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private var isRunning = false
    private var outputFormat: AVAudioFormat?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?

    private var engine: AVAudioEngine?
    /// エンジンを作るたびに増やす番号。古いエンジンから届いた通知を見分けるために使う。
    private var engineGeneration = 0
    private var configurationObserver: (any NSObjectProtocol)?
    private var configurationSignal: AsyncStream<Int>.Continuation?
    private var configurationTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Audio")

    public init() {
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw AudioSourceError.alreadyRunning }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (signals, signal) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
        self.outputFormat = outputFormat
        self.chunkContinuation = chunkContinuation
        self.configurationSignal = signal

        do {
            try startEngine()
        } catch {
            chunkContinuation.finish()
            signal.finish()
            self.outputFormat = nil
            self.chunkContinuation = nil
            self.configurationSignal = nil
            throw error
        }

        isRunning = true
        // 通知は続けて何度も来ることがあるので、1本の Task で直列に処理する（溜めるのは最新の1件だけ）。
        configurationTask = Task { [weak self] in
            for await generation in signals {
                await self?.handleConfigurationChange(generation: generation)
            }
        }
        return chunks
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        configurationTask?.cancel()
        configurationTask = nil
        configurationSignal?.finish()
        configurationSignal = nil
        tearDownEngine()
        chunkContinuation?.finish()
        chunkContinuation = nil
        outputFormat = nil
        levelContinuation.yield(0)
    }

    // MARK: - AVAudioEngine

    private func startEngine() throws {
        guard let outputFormat, let chunkContinuation else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // 0Hz / 0ch のまま installTap すると、Swift で捕まえられない例外になる（AVAudioEngine.h）。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioSourceError.noInputDevice
        }

        let processor = TapProcessor(
            inputFormat: inputFormat,
            converter: try StreamingAudioConverter(from: inputFormat, to: outputFormat),
            chunks: chunkContinuation,
            levels: levelContinuation
        )
        // tap の bufferSize の対応範囲は 100〜400ms（AVAudioNode.h）。遅延を抑えるため最小の 100ms にする。
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: Self.makeTapBlock(processor))

        // 開始までの間に来た通知も落とさないよう、observer は engine.start() より前に付ける。
        engineGeneration += 1
        let generation = engineGeneration
        let signal = configurationSignal
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            // 通知は内部のキューで届く。ここではエンジンに触らず、どのエンジンの通知かを actor へ知らせるだけにする。
            signal?.yield(generation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineStartFailed(error.localizedDescription)
        }
        configurationObserver = observer
        self.engine = engine
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// 入力デバイスの変更に追従する。通知が来た時点でエンジンは止まっているので、エンジンごと作り直す。
    /// - Parameter generation: 通知を出したエンジンの番号。今のエンジンのものでなければ無視する
    ///   （作り直しの前に溜まった通知で、作ったばかりのエンジンをもう一度壊さないため）。
    private func handleConfigurationChange(generation: Int) async {
        guard isRunning, generation == engineGeneration else { return }
        // 切り替えの直後は通知が続けて来たり、入力形式が定まっていなかったりするので少し待つ。
        try? await Task.sleep(for: .milliseconds(250))
        // 待っている間に stop（とその後の start）が走った場合は、新しいエンジンに触らない。
        guard isRunning, !Task.isCancelled, generation == engineGeneration else { return }

        tearDownEngine()
        levelContinuation.yield(0)

        var attempt = 0
        while isRunning, !Task.isCancelled {
            do {
                try startEngine()
                Self.logger.info("入力デバイスの変更後、録音を再開した")
                return
            } catch {
                attempt += 1
                if attempt == 1 {
                    Self.logger.error("入力デバイスの変更後に再開できない。再試行する: \(String(describing: error), privacy: .public)")
                }
                // 最初の数回は短い間隔で、その後はデバイスがつながるまで1秒おきに試す。ストリームは開いたままにする。
                let delay: Duration = attempt < 10 ? .milliseconds(500) : .seconds(1)
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// tap のブロックを作る。`@Sendable` を明示して actor に分離されないようにする
    /// （分離されたクロージャをオーディオのスレッドから呼ぶと、実行時の分離チェックで落ちる）。
    private nonisolated static func makeTapBlock(
        _ processor: TapProcessor
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in processor.process(buffer) }
    }
}

/// tap のコールバックで行う処理。
///
/// ここでは自前のロック、actor への移動、await、ログ出力、ファイル入出力、変換器の生成をしない。
/// 行うのは、変換・レベル計算・AsyncStream への yield の3つだけ。
/// （tap のブロックはリアルタイムの I/O スレッドではなく、メイン以外のスレッドで呼ばれる。
/// yield は内部で短いロックを取るが、DESIGN.md §2 の設計どおりストリームで受け渡す。）
final class TapProcessor: @unchecked Sendable {
    // @unchecked の理由: process は tap のスレッドだけから直列に呼ばれる。フィールドはすべて let で、
    // 中の変換器を触るのもそのスレッドだけ。tap を付け直すときは新しいインスタンスを作るので、共有されない。
    private let inputFormat: AVAudioFormat
    private let converter: StreamingAudioConverter
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let levels: AsyncStream<Float>.Continuation

    init(
        inputFormat: AVAudioFormat,
        converter: StreamingAudioConverter,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<Float>.Continuation
    ) {
        self.inputFormat = inputFormat
        self.converter = converter
        self.chunks = chunks
        self.levels = levels
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        // 付け直しの直後に古い形式のバッファが来た場合は捨てる。
        guard buffer.format.sampleRate == inputFormat.sampleRate,
              buffer.format.channelCount == inputFormat.channelCount else { return }

        levels.yield(AudioLevel.normalized(rms: AudioLevel.rms(of: buffer)))
        if let converted = try? converter.convert(buffer) {
            chunks.yield(AudioChunk(buffer: converted))
        }
    }
}
