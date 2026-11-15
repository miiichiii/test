import Foundation

/// セッション（1回の会議）の情報。`meta.json` に保存する。
public struct SessionMeta: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// 録音中（一時停止中を含む）。この状態のまま残っていれば、異常終了したセッション（Phase 5 でそう扱う）
        case recording
        /// 停止して保存を終えた
        case finished
    }

    public let id: UUID
    public var title: String
    /// 録音を始めた日時
    public var startedAt: Date
    /// 録音時間（一時停止中を除く秒数）。終了時に書く
    public var duration: TimeInterval?
    public var status: Status

    public init(id: UUID = UUID(), title: String, startedAt: Date, duration: TimeInterval? = nil, status: Status = .recording) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.status = status
    }
}
