import LiveMinutesKit
import SwiftUI

@main
struct LiveMinutesApp: App {
    @State private var model = LiveTranscriptionModel(
        engine: AppleSpeechEngine(locale: Locale(identifier: "ja-JP")),
        source: MicrophoneSource(),
        permission: SystemMicrophonePermission()
    )

    var body: some Scene {
        // 会議は同時に1つだけ扱うので、複数開ける WindowGroup ではなく単一の Window にする。
        Window("LiveMinutes", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 960, height: 600)
    }
}
