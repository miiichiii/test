import LiveMinutesKit
import SwiftUI

/// ツールバー: 開始 / 一時停止 / 再開 / 停止、状態、経過時間、入力レベル。
struct RecordingToolbar: ToolbarContent {
    let controller: SessionController
    /// 「開始」を押したとき（会議名の入力シートを出す）
    let onStart: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            NotesStatusLabel(status: controller.notes.status)
            Toggle(isOn: Binding(
                get: { controller.notes.isSendingPaused },
                set: { controller.setNotesSendingPaused($0) }
            )) {
                Label("要約の送信を一時停止", systemImage: controller.notes.isSendingPaused ? "eye.slash.fill" : "eye.slash")
            }
            .toggleStyle(.button)
            // 会議中だけ切り替えられる（新しい会議ではオフから始まるので、開始前に押しても効かないため）。
            .disabled(!(controller.state == .recording || controller.state == .paused))
            .help("オンの間に話した内容は、ノートの整理に使わず OpenAI にも送りません（文字起こしには残ります）。オンにした時点でまだ送っていない発言も送りません")

            StatusLabel(state: controller.state, activity: controller.activity)
            ElapsedTimeLabel(controller: controller)
            LevelMeter(controller: controller)

            Button(action: onStart) {
                Label("開始", systemImage: "record.circle")
            }
            .disabled(!canStart)
            .help("新しい会議の文字起こしを開始する")

            if controller.state == .paused {
                Button {
                    Task { await controller.resume() }
                } label: {
                    Label("再開", systemImage: "play.circle")
                }
                .disabled(controller.isBusy)
                .help("文字起こしを再開する")
            } else {
                Button {
                    Task { await controller.pause() }
                } label: {
                    Label("一時停止", systemImage: "pause.circle")
                }
                .disabled(controller.state != .recording || controller.isBusy)
                .help("マイクを止めて一時停止する。一時停止中の音声は文字にしない")
            }

            Button {
                Task { await controller.stop() }
            } label: {
                Label("停止", systemImage: "stop.circle")
            }
            .disabled(!(controller.state == .recording || controller.state == .paused) || controller.isBusy)
            .help("文字起こしを終えて保存する")
        }
    }

    private var canStart: Bool {
        (controller.state == .idle || controller.state == .finished) && !controller.isBusy
    }
}

private struct StatusLabel: View {
    let state: SessionController.State
    let activity: SessionController.Activity?

    var body: some View {
        switch (state, activity) {
        case (_, .resuming?):
            Text("再開中…").foregroundStyle(.secondary)
        case (.paused, .pausing?):
            Text("一時停止中（確定中…）").foregroundStyle(.secondary)
        case (.idle, _), (.finished, _):
            EmptyView()
        case (.preparing, _):
            Text("準備中…").foregroundStyle(.secondary)
        case (.recording, _):
            Label("録音中", systemImage: "waveform")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
        case (.paused, _):
            Label("一時停止中", systemImage: "pause.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        case (.finishing, _):
            Text("確定中…").foregroundStyle(.secondary)
        }
    }
}

/// 録音経過時間。一時停止中は進まない。
private struct ElapsedTimeLabel: View {
    let controller: SessionController

    var body: some View {
        if controller.sessionMeta != nil {
            // 毎秒の表示更新はこの View だけで行う。秒の境目を飛ばさないよう、半秒ごとに読み直す。
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(ElapsedTimeFormat.string(controller.elapsed()))
                    .monospacedDigit()
                    .foregroundStyle(controller.state == .recording ? .primary : .secondary)
            }
        }
    }
}

/// 入力レベルのメーター。レベルはこの View だけで読み、ほかの View を再描画させない。
private struct LevelMeter: View {
    let controller: SessionController

    var body: some View {
        let level = CGFloat(controller.inputLevel)
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.green)
                        .frame(width: proxy.size.width * level)
                }
            }
            .frame(width: 80, height: 6)
            .animation(.linear(duration: 0.1), value: level)
            // 1秒に何度も変わる値なので、読み上げの対象から外す（独自のラベルが循環して落ちる問題を避けるため）。
            .accessibilityHidden(true)
    }
}

/// ノートのライブ更新の状態（更新中 / 待機 / エラー）。
private struct NotesStatusLabel: View {
    let status: LiveNotesStatus

    var body: some View {
        switch status {
        case .inactive, .notConfigured:
            EmptyView()
        case .waiting:
            Label("ノート: 待機", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        case .updating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("ノート: 更新中").foregroundStyle(.secondary)
            }
        case .offline:
            Label("ノート: オフライン", systemImage: "wifi.slash")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        case .paused:
            Label("ノート: 送信停止中", systemImage: "pause.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        case .failed:
            Label("ノート: エラー", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .help("右のノートペインに理由を表示しています")
        }
    }
}
