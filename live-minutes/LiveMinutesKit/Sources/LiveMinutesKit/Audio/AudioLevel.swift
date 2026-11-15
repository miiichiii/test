import AVFAudio
import Foundation

/// 入力レベル（メーター表示用）の計算。tap のコールバックから呼ぶので、確保もロックもしない。
public enum AudioLevel {
    /// この値（dBFS）以下を 0 とする。
    public static let floorDecibels: Float = -60

    /// RMS（0…1）を、-60dBFS〜0dBFS が 0…1 になるよう対応させる。
    public static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }

    /// バッファ全体（全チャンネル）の RMS。Float32 と Int16 の PCM を扱う。それ以外は 0 を返す。
    public static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        // インターリーブ形式では先頭のポインタに全チャンネル分が交互に並ぶ。
        let pointers = buffer.format.isInterleaved ? 1 : channels
        let samplesPerPointer = buffer.format.isInterleaved ? frames * channels : frames
        var sumOfSquares: Float = 0

        if let data = buffer.floatChannelData {
            for p in 0..<pointers {
                let samples = data[p]
                for i in 0..<samplesPerPointer {
                    let s = samples[i]
                    sumOfSquares += s * s
                }
            }
        } else if let data = buffer.int16ChannelData {
            for p in 0..<pointers {
                let samples = data[p]
                for i in 0..<samplesPerPointer {
                    let s = Float(samples[i]) / Float(Int16.max)
                    sumOfSquares += s * s
                }
            }
        } else {
            return 0
        }
        return (sumOfSquares / Float(frames * channels)).squareRoot()
    }
}
