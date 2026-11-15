import SwiftUI

@main
struct LiveMinutesApp: App {
    var body: some Scene {
        // 会議は同時に1つだけ扱うので、複数開ける WindowGroup ではなく単一の Window にする。
        Window("LiveMinutes", id: "main") {
            MainView()
        }
        .defaultSize(width: 960, height: 600)
    }
}
