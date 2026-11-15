import AVFAudio

/// 連続して届く音声バッファを、別の形式（サンプルレート・チャンネル数・サンプル型）へ変換する。
///
/// 1つの `AVAudioConverter` をバッファをまたいで使い続ける。リサンプリングの途中状態を持ち越すため、
/// 入力ブロックでは `.endOfStream` を返さない（返すと、その変換器は以後何も出力しなくなる）。
///
/// スレッド安全ではない。1つのスレッドから直列に呼ぶこと（`MicrophoneSource` では tap のスレッドだけが呼ぶ）。
public final class StreamingAudioConverter {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioSourceError.converterUnavailable
        }
        // 多チャンネルから少ないチャンネルへ変換するときは、先頭チャンネルだけでなく全体を混ぜる。
        if outputFormat.channelCount < inputFormat.channelCount {
            converter.downmix = true
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// 1バッファ分を変換する。出力が0フレームだった場合（リサンプラが溜めている途中など）は nil を返す。
    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // リサンプラが前回分を持ち越して少し多めに出すことがあるので、余裕を持たせる。
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var conversionError: NSError?
        // 入力ブロックは convert の中から同じスレッドで同期的に呼ばれる（NS_NOESCAPE）。
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw conversionError ?? AudioSourceError.converterUnavailable
        }
        return output.frameLength > 0 ? output : nil
    }
}
