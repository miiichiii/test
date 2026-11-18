import LiveMinutesKit
import SwiftUI

/// メニューの「会議」とキーボードショートカット（Phase 6）。
///
/// ショートカットからの開始は、会議名の入力を省き、開始日時から名前を付ける（ウィンドウが隠れていても使えるように）。
struct MeetingCommands: Commands {
    let controller: SessionController

    var body: some Commands {
        CommandMenu("会議") {
            MeetingMenuItems(controller: controller)
        }
    }
}

/// 開始 / 一時停止 / 再開 / 停止 / 要約の送信を一時停止（メニューとメニューバーで共有する）。
struct MeetingMenuItems: View {
    let controller: SessionController

    var body: some View {
        Button("開始") { Task { await controller.start() } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!controller.canStart)
        if controller.state == .paused {
            Button("再開") { Task { await controller.resume() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!controller.canResume)
        } else {
            Button("一時停止") { Task { await controller.pause() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!controller.canPause)
        }
        Button("停止") { Task { await controller.stop() } }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!controller.canStop)
        Divider()
        Toggle("要約の送信を一時停止", isOn: Binding(
            get: { controller.notes.isSendingPaused },
            set: { controller.setNotesSendingPaused($0) }
        ))
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .disabled(!(controller.state == .recording || controller.state == .paused))
    }
}

/// メニューバーの中身。
struct MenuBarContent: View {
    let controller: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        Divider()
        MeetingMenuItems(controller: controller)
        Divider()
        Button("ウィンドウを開く") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        Button("LiveMinutes を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch controller.state {
        case .idle, .finished: "待機中"
        case .preparing: "準備中…"
        case .recording: "録音中 \(ElapsedTimeFormat.string(controller.elapsed()))"
        case .paused: "一時停止中"
        case .finishing: "確定中…"
        }
    }
}

/// メニューバーのアイコン。録音中は塗りつぶしにして、録音していることが分かるようにする。
enum MenuBarIcon {
    static func systemImage(for state: SessionController.State) -> String {
        switch state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        default: "waveform.circle"
        }
    }
}
