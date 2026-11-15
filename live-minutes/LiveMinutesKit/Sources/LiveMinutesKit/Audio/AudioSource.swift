import AVFAudio
import Foundation

/// 変換済みの音声バッファ1つ分。
public struct AudioChunk: @unchecked Sendable {
    // @unchecked の理由: buffer は送り手（tap や FakeAudioSource）が毎回新しく確保したもので、
    // ストリームへ渡した後は送り手も受け手も書き換えない。読むだけなので、別のスレッドへ渡しても競合しない。
    // （Speech の AnalyzerInput も、同じ前提で AVAudioPCMBuffer を持つ Sendable 型になっている。）
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// 音声の入力元。文字起こし側はこの protocol だけに依存する（DESIGN.md §4.1）。
///
/// - `start(outputFormat:)` は、指定した形式に変換した音声のストリームを返す。変換はソース側で行う
/// - `stop()` でストリームが終わる。`stop()` の後にもう一度 `start(outputFormat:)` を呼ぶと、新しいストリームを返す
/// - `levels` は開始・停止をまたいで1本だけ存在する入力レベル（0…1）のストリーム。読み手は1つだけにする
public protocol AudioSource: AnyObject, Sendable {
    var levels: AsyncStream<Float> { get }
    func start(outputFormat: AVAudioFormat) async throws -> AsyncStream<AudioChunk>
    func stop() async
}

public enum AudioSourceError: Error, Equatable, Sendable {
    /// 入力デバイスがない（入力形式のサンプルレートかチャンネル数が0）
    case noInputDevice
    /// すでに開始している
    case alreadyRunning
    /// 入力形式から出力形式への変換器を作れない
    case converterUnavailable
    /// AVAudioEngine を開始できない
    case engineStartFailed(String)
}

extension AudioSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "マイクが見つかりません"
        case .alreadyRunning: "録音はすでに開始しています"
        case .converterUnavailable: "マイクの音声を音声認識用の形式に変換できません"
        case .engineStartFailed: "マイクの録音を開始できません"
        }
    }
}
