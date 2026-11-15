import AVFAudio
import Foundation

/// 用意したバッファを流すだけの `AudioSource`。マイクなしでテストするために使う。
///
/// `start(outputFormat:)` で、渡されたバッファを順にすべて流す。`finishWhenDrained` が true なら
/// 流し終えた時点でストリームを終える。false なら `stop()` まで開いたままにする（マイクと同じ）。
public actor FakeAudioSource: AudioSource {
    public nonisolated let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private let chunks: [AudioChunk]
    private let finishWhenDrained: Bool
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    /// `start(outputFormat:)` が呼ばれた回数
    public private(set) var startCount = 0
    /// `start(outputFormat:)` に渡された形式
    public private(set) var requestedFormats: [AVAudioFormat] = []

    public init(chunks: [AudioChunk], finishWhenDrained: Bool = false) {
        self.chunks = chunks
        self.finishWhenDrained = finishWhenDrained
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        guard continuation == nil else { throw AudioSourceError.alreadyRunning }
        startCount += 1
        requestedFormats.append(outputFormat)

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        for chunk in chunks {
            levelContinuation.yield(AudioLevel.normalized(rms: AudioLevel.rms(of: chunk.buffer)))
            continuation.yield(chunk)
        }
        if finishWhenDrained {
            continuation.finish()
        } else {
            self.continuation = continuation
        }
        return stream
    }

    public func stop() async {
        continuation?.finish()
        continuation = nil
        levelContinuation.yield(0)
    }
}

/// テスト用の音声バッファを作る。
public enum TestTone {
    /// サイン波のバッファを作る。形式は Float32 か Int16 の PCM（インターリーブでもよい）。
    /// - Parameter startFrame: 連続したバッファを作るときの開始位置（位相をつなげるため）
    public static func sine(
        format: AVAudioFormat,
        frequency: Double = 440,
        amplitude: Float = 0.5,
        frameCount: AVAudioFrameCount,
        startFrame: Int = 0
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let frames = Int(frameCount)
        let channels = Int(format.channelCount)
        let pointers = format.isInterleaved ? 1 : channels
        let stride = format.isInterleaved ? channels : 1

        func sample(_ frame: Int) -> Float {
            amplitude * Float(sin(2 * Double.pi * frequency * Double(startFrame + frame) / format.sampleRate))
        }

        if let data = buffer.floatChannelData {
            for p in 0..<pointers {
                for frame in 0..<frames {
                    for c in 0..<stride {
                        data[p][frame * stride + c] = sample(frame)
                    }
                }
            }
        } else if let data = buffer.int16ChannelData {
            for p in 0..<pointers {
                for frame in 0..<frames {
                    for c in 0..<stride {
                        data[p][frame * stride + c] = Int16(sample(frame) * Float(Int16.max))
                    }
                }
            }
        } else {
            return nil
        }
        return buffer
    }
}
