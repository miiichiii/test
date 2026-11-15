import Foundation

/// 確定した文字起こしの1区間。時刻は録音開始からの秒数（投入した音声の累積時間が基準）。
public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 文字起こしエンジンが流すイベント。
public enum TranscriptEvent: Equatable, Sendable {
    /// 未確定の途中結果。直前の未確定結果を置き換える
    case volatile(String)
    /// 確定した区間。未確定表示は消す
    case final(TranscriptSegment)
}

public enum TranscriptionError: Error, Equatable, Sendable {
    /// この Mac では端末内の音声認識が使えない
    case transcriberUnavailable
    /// 指定したロケールに対応していない（値はロケールの識別子）
    case unsupportedLocale(String)
    /// 音声認識モデルのダウンロードや導入に失敗した
    case modelDownloadFailed(String)
    /// 音声認識に渡せる音声の形式が得られない
    case noCompatibleAudioFormat
    /// prepare が済んでいない
    case notPrepared
    /// すでに開始している
    case alreadyRunning
    /// 停止操作をしていないのに、音声認識の結果が途中で終わった
    case recognitionEnded
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable: "この Mac では端末内の音声認識を使えません"
        case .unsupportedLocale(let identifier): "音声認識が \(identifier) に対応していません"
        case .modelDownloadFailed: "音声認識モデルのダウンロードに失敗しました"
        case .noCompatibleAudioFormat: "音声認識に渡せる音声の形式が見つかりません"
        case .notPrepared: "音声認識の準備ができていません"
        case .alreadyRunning: "文字起こしはすでに開始しています"
        case .recognitionEnded: "音声認識が途中で終了しました"
        }
    }
}

/// 文字起こしエンジン。
///
/// - `prepare(progress:)`: ロケールの確認、モデルの導入、入力形式の決定。一度成功すれば以後は呼ばなくてよい
/// - `start(source:)`: 音声ソースを開始し、イベントのストリームを返す。途中で失敗した場合は、ソースを止めてから
///   ストリームをエラーで終える
/// - `stop()`: ソースを止め、最後の未確定分まで確定させてからストリームを終える
public protocol TranscriptionEngine: AnyObject, Sendable {
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func start(source: any AudioSource) async throws -> AsyncThrowingStream<TranscriptEvent, any Error>
    func stop() async
}

/// 認識結果1件を `TranscriptEvent` に変換する。
enum TranscriptEventMapper {
    /// - Parameters:
    ///   - start, end: 結果の時間範囲（秒）。有限でない場合は `lastEnd` に寄せる
    ///   - lastEnd: 直前に確定した区間の終わり
    /// - Returns: 空の確定結果は nil（表示しても意味がないため）
    static func event(text: String, isFinal: Bool, start: Double, end: Double, lastEnd: Double) -> TranscriptEvent? {
        guard isFinal else { return .volatile(text) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let safeStart = start.isFinite ? start : lastEnd
        let safeEnd = end.isFinite ? max(end, safeStart) : safeStart
        return .final(TranscriptSegment(start: safeStart, end: safeEnd, text: text))
    }
}
