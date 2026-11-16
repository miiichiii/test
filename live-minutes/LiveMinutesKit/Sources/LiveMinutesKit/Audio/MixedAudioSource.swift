import AVFAudio
import Foundation
import os

/// マイクと Mac 内の音声を足し合わせる（純粋なロジック。Phase 7）。
///
/// マイクを時計にする: マイクの音が届いたら、その長さの分だけ Mac 内の音声をためたものから取り出して足す。
/// Mac 内の音声が足りなければ、その分は足さない（許可を拒否されて届かない場合も、マイクだけで続く）。
/// ためる量には上限を設け、超えたら古いものを捨てる（遅れが積み重ならないように）。
struct AudioMixer {
    let maxQueuedSamples: Int
    private(set) var systemQueue: [Float] = []

    init(maxQueuedSamples: Int) {
        self.maxQueuedSamples = max(maxQueuedSamples, 0)
    }

    mutating func appendSystem(_ samples: [Float]) {
        systemQueue += samples
        if systemQueue.count > maxQueuedSamples {
            systemQueue.removeFirst(systemQueue.count - maxQueuedSamples)
        }
    }

    /// マイクの音に Mac 内の音声を足す。-1…1 に収める
    mutating func mix(microphone: [Float]) -> [Float] {
        let count = min(microphone.count, systemQueue.count)
        guard count > 0 else { return microphone }
        var mixed = microphone
        for index in 0..<count {
            mixed[index] = min(max(microphone[index] + systemQueue[index], -1), 1)
        }
        systemQueue.removeFirst(count)
        return mixed
    }
}

/// マイクと Mac 内の音声を混ぜて1本にする `AudioSource`（Phase 7。DESIGN.md §4.1）。
///
/// - 取り込みがオフなら、マイクをそのまま使う（今までと同じ動作）。開始のたびに設定を読む
/// - オンなら、両方を 32 ビット浮動小数点・モノラル（求められたレート）で受け、足し合わせてから、求められた形式に変換する
/// - Mac 内の音声を始められなかったら、マイクだけで続ける
/// - 入力レベルはマイクのものを使う
public actor MixedAudioSource: AudioSource {
    private let microphone: any AudioSource
    private let system: any AudioSource
    private let isSystemAudioEnabled: @MainActor @Sendable () -> Bool

    private var mixer = AudioMixer(maxQueuedSamples: 0)
    private var mixFormat: AVAudioFormat?
    private var converter: StreamingAudioConverter?
    private var output: AsyncStream<AudioChunk>.Continuation?
    private var microphoneTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?
    private var isSystemRunning = false
    private var isRunning = false

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Audio")

    public init(
        microphone: any AudioSource,
        system: any AudioSource,
        isSystemAudioEnabled: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.microphone = microphone
        self.system = system
        self.isSystemAudioEnabled = isSystemAudioEnabled
    }

    public nonisolated var levels: AsyncStream<Float> { microphone.levels }

    public func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        guard !isRunning else { throw AudioSourceError.alreadyRunning }
        guard await isSystemAudioEnabled() else {
            // オフ: マイクをそのまま渡す。
            isRunning = true
            isSystemRunning = false
            return try await microphone.start(outputFormat: outputFormat)
        }
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outputFormat.sampleRate, channels: 1, interleaved: false
        ) else { throw AudioSourceError.converterUnavailable }

        let microphoneChunks = try await microphone.start(outputFormat: mixFormat)
        let converter = try StreamingAudioConverter(from: mixFormat, to: outputFormat)
        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.mixFormat = mixFormat
        self.converter = converter
        output = continuation
        // ためるのは最大 1 秒分。
        mixer = AudioMixer(maxQueuedSamples: Int(outputFormat.sampleRate))
        isRunning = true

        do {
            let systemChunks = try await system.start(outputFormat: mixFormat)
            isSystemRunning = true
            systemTask = Task { [weak self] in
                for await chunk in systemChunks {
                    await self?.appendSystem(chunk)
                }
            }
        } catch {
            Self.logger.error("Mac 内の音声を始められないため、マイクだけで続ける: \(String(describing: type(of: error)), privacy: .public)")
        }

        microphoneTask = Task { [weak self] in
            for await chunk in microphoneChunks {
                await self?.mixAndYield(chunk)
            }
            await self?.microphoneDidEnd()
        }
        return chunks
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        await microphone.stop()
        if isSystemRunning {
            await system.stop()
            isSystemRunning = false
        }
        await microphoneTask?.value
        systemTask?.cancel()
        systemTask = nil
        microphoneTask = nil
        output?.finish()
        output = nil
        converter = nil
        mixFormat = nil
    }

    private func appendSystem(_ chunk: AudioChunk) {
        guard let samples = Self.samples(of: chunk.buffer) else { return }
        mixer.appendSystem(samples)
    }

    private func mixAndYield(_ chunk: AudioChunk) {
        guard let mixFormat, let converter, let samples = Self.samples(of: chunk.buffer) else { return }
        let mixed = mixer.mix(microphone: samples)
        guard let buffer = Self.buffer(mixed, format: mixFormat),
              let converted = try? converter.convert(buffer) else { return }
        output?.yield(AudioChunk(buffer: converted))
    }

    /// マイクのストリームが終わった（停止、またはマイクの失敗）。出力も終える。
    private func microphoneDidEnd() async {
        guard isRunning else { return }
        output?.finish()
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }
}
