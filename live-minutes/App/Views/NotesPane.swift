import AppKit
import LiveMinutesKit
import SwiftUI

/// 右ペイン: トピックごとに項目を並べる。種類はラベルの文字つきのバッジで示し、ToDo には担当と期限を添える。
struct NotesPane: View {
    let controller: SessionController
    /// 今の接続方法（未設定の案内と「ChatGPT プランを使用中」の表示に使う）
    let authMethod: AuthMethod

    private var store: NotesStore { controller.notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "ノート") {
                Button {
                    let title = controller.sessionMeta?.title ?? "ノート"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(NotesExporter.markdown(title: title, notes: store.notes), forType: .string)
                } label: {
                    Label("Markdown をコピー", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.notes.isEmpty)
                .help("ノートを Markdown としてコピーする")
            }

            if showsPlanUsage {
                PlanUsageBar()
            }

            NotesStatusBanner(controller: controller, authMethod: authMethod)

            if store.notes.isEmpty {
                NotesPlaceholder(status: store.status, isSessionActive: controller.state == .recording || controller.state == .paused)
            } else {
                NotesList(store: store, controller: controller)
            }
        }
    }

    /// ChatGPT のプランで動いている間だけ出す（要ログインで止まっている間は出さない。案内と矛盾するため）。
    private var showsPlanUsage: Bool {
        guard authMethod == .chatGPTPlan else { return false }
        switch store.status {
        case .waiting, .updating, .paused, .offline:
            return true
        case .failed(_, _, let action):
            return action != .signIn
        case .inactive, .notConfigured:
            return false
        }
    }
}

/// 「ChatGPT プランを使用中」と「使用量を管理」（UI/UX guidelines の「Using ChatGPT plan」「Manage usage」）。
private struct PlanUsageBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Label("ChatGPT プランを使用中", systemImage: "checkmark.seal")
                .lineLimit(1)
            Spacer(minLength: 4)
            if let usage = ChatGPTLinks.usage {
                Link("使用量を管理", destination: usage)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
    }
}

/// 案内（未設定、失敗、一時停止中、反映できなかった発言）。
private struct NotesStatusBanner: View {
    let controller: SessionController
    let authMethod: AuthMethod

    var body: some View {
        let store = controller.notes
        VStack(alignment: .leading, spacing: 0) {
            switch store.status {
            case .notConfigured:
                Banner(systemImage: "key", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(notConfiguredMessage)
                        SettingsLink {
                            Text("設定を開く")
                        }
                    }
                }
            case .failed(let message, let needsRetry, let action):
                Banner(systemImage: "exclamationmark.triangle", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                        Text(needsRetry ? Self.hint(for: action) : "しばらくしてから自動で送り直します。文字起こしは続いています。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if needsRetry {
                            HStack {
                                Button("再試行") { controller.retryNotes() }
                                switch action {
                                case .manageUsage:
                                    if let usage = ChatGPTLinks.usage {
                                        Link("使用量を管理", destination: usage)
                                    }
                                case .signIn:
                                    SettingsLink { Text("設定を開いてログイン") }
                                case .checkSettings:
                                    SettingsLink { Text("設定を開く") }
                                }
                            }
                        }
                    }
                }
            case .offline:
                Banner(systemImage: "wifi.slash", tint: .gray) {
                    Text("オフライン。文字起こしは継続中です。ネットワークにつながったら、ノートの整理を自動で再開します。")
                }
            case .paused:
                Banner(systemImage: "pause.circle", tint: .gray) {
                    Text("要約の送信を一時停止しています。この間の発言はノートに使いません（文字起こしには残ります）。")
                }
            case .inactive, .waiting, .updating:
                EmptyView()
            }
            if store.hasDroppedSegments {
                Banner(systemImage: "text.badge.xmark", tint: .yellow) {
                    Text("一部の発言をノートに反映できませんでした（文字起こしには残っています）。")
                }
            }
        }
    }

    private var notConfiguredMessage: String {
        switch authMethod {
        case .apiKey:
            "OpenAI の API キーが設定されていないため、ノートは作りません。文字起こしは続きます。"
        case .chatGPTPlan:
            "ChatGPT にログインしていないか、プランの利用が許可されていない（またはログインの情報を読めない）ため、ノートは作りません。文字起こしは続きます。"
        }
    }

    /// 止まったときの補足（次に何をすればよいか）
    private static func hint(for action: NotesFailureAction) -> String {
        switch action {
        case .checkSettings:
            "設定を確かめてから「再試行」を押してください。文字起こしは続いています。"
        case .manageUsage:
            "ChatGPT の使用量の画面で、プランかこのアプリの上限を確かめてください。使えるようになったら「再試行」を押してください。文字起こしは続いています。"
        case .signIn:
            "設定画面で ChatGPT にログインし直すと、自動で再開します。文字起こしは続いています。"
        }
    }
}

private struct Banner<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
            content
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }
}

private struct NotesPlaceholder: View {
    let status: LiveNotesStatus
    /// 録音中か一時停止中（エンジンを作っている間は `inactive` のままなので、これで見分ける）
    let isSessionActive: Bool

    var body: some View {
        Text(message)
            .foregroundStyle(.tertiary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var message: String {
        switch status {
        case .waiting, .updating, .failed, .paused, .offline:
            "話した内容が整理されて、ここに箇条書きで増えていきます。"
        case .inactive where isSessionActive:
            "ノートの整理の準備をしています…"
        case .inactive, .notConfigured:
            "会議を開始すると、話した内容をここに整理します。"
        }
    }
}

private struct NotesList: View {
    let store: NotesStore
    let controller: SessionController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(store.notes.topics) { topic in
                    TopicView(topic: topic, changedIDs: store.recentlyChangedIDs, controller: controller)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

private struct TopicView: View {
    let topic: Topic
    let changedIDs: Set<String>
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title)
                .font(.headline)
                .padding(.horizontal, 4)
                .background(highlight(changedIDs.contains(topic.id)))
            ForEach(topic.items) { item in
                NoteItemRow(item: item, isHighlighted: changedIDs.contains(item.id), controller: controller)
            }
        }
    }
}

private struct NoteItemRow: View {
    let item: NoteItem
    let isHighlighted: Bool
    let controller: SessionController
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindBadge(kind: item.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("手で直した項目です。この後の自動の整理では書き換えません")
                    }
                }
                let suffix = details
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(highlight(isHighlighted))
        .animation(.easeOut(duration: 0.6), value: isHighlighted)
        .accessibilityElement(children: .combine)
        // 会議中（ライブ更新が動いている間）だけ、手で直せる（Phase 6）。
        .contextMenu {
            if controller.canEditNotes {
                Button("文言を直す…") {
                    draft = item.text
                    isEditing = true
                }
                Button("削除", role: .destructive) { controller.deleteNoteItem(id: item.id) }
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("項目の文言を直す").font(.headline)
                TextField("文言", text: $draft, axis: .vertical)
                    .lineLimit(2...6)
                    .frame(minWidth: 360)
                Text("直した項目は固定し、この後の自動の整理では書き換えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("キャンセル", role: .cancel) { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") {
                        controller.editNoteItem(id: item.id, text: draft)
                        isEditing = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let owner = item.owner { parts.append("担当: \(owner)") }
        if let due = item.due { parts.append("期限: \(due)") }
        return parts.joined(separator: "　")
    }
}

/// 種類のバッジ。色だけに頼らず、ラベルの文字でも種類が分かるようにする。
private struct KindBadge: View {
    let kind: NoteKind

    var body: some View {
        Text(kind.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 40)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch kind {
        case .point: .blue
        case .decision: .green
        case .action: .orange
        case .question: .purple
        }
    }
}

private func highlight(_ isOn: Bool) -> some View {
    RoundedRectangle(cornerRadius: 4)
        .fill(isOn ? Color.yellow.opacity(0.3) : Color.clear)
}
