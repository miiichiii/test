import Foundation

/// `SessionController` が使う時計。テストでは手で進める偽物に差し替える。
@MainActor
public protocol SessionClock: AnyObject {
    /// 現在の日時（`meta.json` の開始日時と、既定の会議名に使う）
    func now() -> Date
    /// 単調に増える秒数（録音経過時間の計算に使う）。スリープ中は進まないこと
    func uptime() -> TimeInterval
}

/// 実際の時計。経過時間には、スリープ中に進まない `SuspendingClock` を使う
/// （スリープ中はマイクも止まるので、その間を録音時間に数えない）。
@MainActor
public final class SystemSessionClock: SessionClock {
    private let clock = SuspendingClock()
    private let origin: SuspendingClock.Instant

    public init() {
        origin = clock.now
    }

    public func now() -> Date { Date() }

    public func uptime() -> TimeInterval {
        let elapsed = origin.duration(to: clock.now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
    }
}
