import Foundation

/// `NotesEngine` が使う時計。テストでは手で進める偽物に差し替える。
///
/// 時刻は単調に増える秒数で、スリープ中は進まない（スリープ中はマイクも止まるため）。
public protocol NotesClock: Sendable {
    func now() -> TimeInterval
    /// 指定した時刻まで待つ。すでに過ぎていればすぐに戻る。キャンセルされたら `CancellationError` を投げる
    func sleep(until deadline: TimeInterval) async throws
}

/// 実際の時計（`SuspendingClock`）。
public struct SystemNotesClock: NotesClock {
    private let origin: SuspendingClock.Instant

    public init() {
        origin = SuspendingClock().now
    }

    public func now() -> TimeInterval {
        origin.duration(to: SuspendingClock().now).seconds
    }

    public func sleep(until deadline: TimeInterval) async throws {
        let remaining = deadline - now()
        guard remaining > 0 else {
            try Task.checkCancellation()
            return
        }
        // 切り捨てると少し早く起き、条件の見直しが空回りするので、小数の秒のまま渡す。
        try await Task.sleep(for: .seconds(remaining), clock: .suspending)
    }
}
