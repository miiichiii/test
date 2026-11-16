import Foundation

/// Whisper に渡す音声の区切り（DESIGN.md §4.2「Whisper（ローカル）での書き起こし」）。純粋なロジックで、テストできる。
///
/// 16kHz・モノラルの Float を 100ms ごとの枠で見て、声（エネルギーがしきい値以上）のあとに無音が
/// `silenceDuration` 続いたか、長さが `maxDuration` に達したら区切る。声のない区間は捨てる。
struct WhisperChunker {
    struct Chunk: Equatable {
        let samples: [Float]
        /// 録音開始からの秒数（流し込んだ音声の累積時間が基準）
        let start: TimeInterval
        let end: TimeInterval
    }

    let sampleRate: Double
    let silenceThreshold: Float
    let silenceDuration: TimeInterval
    let maxDuration: TimeInterval
    /// これより短い声の区切りは捨てる（咳や物音で空の書き起こしを作らないため）
    let minSpeechDuration: TimeInterval

    private let frameSize: Int
    /// 区切りの途中の音声
    private(set) var buffer: [Float] = []
    /// `buffer` の先頭の、録音開始からのサンプル位置
    private var bufferStart = 0
    /// 100ms に満たない端数
    private var remainder: [Float] = []
    private var hasSpeech = false
    private var speechFrames = 0
    private var silentFrames = 0

    init(
        sampleRate: Double = 16_000,
        silenceThreshold: Float = 0.01,
        silenceDuration: TimeInterval = 0.6,
        maxDuration: TimeInterval = 15,
        minSpeechDuration: TimeInterval = 0.3
    ) {
        self.sampleRate = sampleRate
        self.silenceThreshold = silenceThreshold
        self.silenceDuration = silenceDuration
        self.maxDuration = maxDuration
        self.minSpeechDuration = minSpeechDuration
        frameSize = max(Int(sampleRate * 0.1), 1)
    }

    /// 区切りの途中に声があるか（途中結果を出すかの判断に使う）
    var isInSpeech: Bool { hasSpeech }

    /// 区切りの途中の音声の長さ（秒）
    var bufferedDuration: TimeInterval { Double(buffer.count) / sampleRate }

    /// 音声を足し、区切れたものを返す。
    mutating func append(_ samples: [Float]) -> [Chunk] {
        var chunks: [Chunk] = []
        var pending = remainder + samples
        var index = 0
        while pending.count - index >= frameSize {
            let frame = Array(pending[index..<(index + frameSize)])
            index += frameSize
            if let chunk = consume(frame) { chunks.append(chunk) }
        }
        pending.removeFirst(index)
        remainder = pending
        return chunks
    }

    /// 残りを最後の区切りとして返す（停止時）。声がなければ nil
    mutating func flush() -> Chunk? {
        buffer += remainder
        remainder = []
        return cut()
    }

    private mutating func consume(_ frame: [Float]) -> Chunk? {
        let isSpeech = Self.rms(frame) >= silenceThreshold
        buffer += frame
        if isSpeech {
            hasSpeech = true
            speechFrames += 1
            silentFrames = 0
        } else {
            silentFrames += 1
        }
        let frameDuration = Double(frameSize) / sampleRate
        if !hasSpeech {
            // 声のない区間は、先頭の 0.2 秒だけ残して捨てる（言い始めの直前を少し含めるため）。
            let keep = Int(sampleRate * 0.2)
            if buffer.count > keep * 2 {
                let drop = buffer.count - keep
                buffer.removeFirst(drop)
                bufferStart += drop
            }
            silentFrames = 0
            return nil
        }
        if Double(silentFrames) * frameDuration >= silenceDuration || bufferedDuration >= maxDuration {
            return cut()
        }
        return nil
    }

    /// 今の区切りを切り出す。声が短すぎれば捨てる。
    private mutating func cut() -> Chunk? {
        defer {
            bufferStart += buffer.count
            buffer = []
            hasSpeech = false
            speechFrames = 0
            silentFrames = 0
        }
        let speechDuration = Double(speechFrames) * Double(frameSize) / sampleRate
        guard hasSpeech, speechDuration >= minSpeechDuration, !buffer.isEmpty else { return nil }
        let start = Double(bufferStart) / sampleRate
        let end = Double(bufferStart + buffer.count) / sampleRate
        return Chunk(samples: buffer, start: start, end: end)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}
