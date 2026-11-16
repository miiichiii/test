import Foundation

/// 録音中のスリープ防止（Phase 6）。テストでは偽物に差し替える。
@MainActor
public protocol SleepPreventing: AnyObject {
    func setPreventsSleep(_ prevents: Bool)
}

/// `ProcessInfo.beginActivity` でアイドルによるシステムのスリープを止める（画面の消灯は止めない）。
@MainActor
public final class SystemSleepPreventer: SleepPreventing {
    private var activity: (any NSObjectProtocol)?

    public init() {}

    public func setPreventsSleep(_ prevents: Bool) {
        if prevents, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "会議を録音・文字起こししているため"
            )
        } else if !prevents, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
