import Foundation
import os
import UserNotifications

/// 無音が続いて自動で一時停止したことを知らせる。テストでは偽物に差し替える。
@MainActor
public protocol AutoPauseNotifying: AnyObject {
    /// - Parameter silence: 一時停止までに待った無音の長さ（秒）
    func notifyAutoPaused(after silence: TimeInterval)
}

/// macOS の通知で知らせる。初めて知らせるときに通知の許可を求める（拒否されたら何もしない。画面の案内は出る）。
@MainActor
public final class SystemAutoPauseNotifier: AutoPauseNotifying {
    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Session")

    public init() {}

    public func notifyAutoPaused(after silence: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "LiveMinutes を一時停止しました"
        content.body = "新しい発言が \(SessionController.minutesText(silence)) なかったためです。続けるときは「再開」を押してください。"
        let request = UNNotificationRequest(identifier: "LiveMinutes.autoPause", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(request)
            } catch {
                Self.logger.error("通知を出せない: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}
