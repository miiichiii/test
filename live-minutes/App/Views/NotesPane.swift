import AppKit
import LiveMinutesKit
import SwiftUI

/// 右ペイン: トピックごとに項目を並べる。種類はラベルの文字つきのバッジで示し、ToDo には担当と期限を添える。
struct NotesPane: View {
    let controller: SessionController

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

            NotesStatusBanner(controller: controller)

            if store.notes.isEmpty {
                NotesPlaceholder(status: store.status)
            } else {
                NotesList(store: store)
            }
        }
    }
}

/// 案内（API キー未設定、失敗、一時停止中、反映できなかった発言）。
private struct NotesStatusBanner: View {
    let controller: SessionController

    var body: some View {
        let store = controller.notes
        VStack(alignment: .leading, spacing: 0) {
            switch store.status {
            case .notConfigured:
                Banner(systemImage: "key", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenAI の API キーが設定されていないため、ノートは作りません。文字起こしは続きます。")
                        SettingsLink {
                            Text("設定を開く")
                        }
                    }
                }
            case .failed(let message, let needsRetry):
                Banner(systemImage: "exclamationmark.triangle", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                        Text(needsRetry ? "設定を確かめてから「再試行」を押してください。文字起こしは続いています。" : "しばらくしてから自動で送り直します。文字起こしは続いています。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if needsRetry {
                            HStack {
                                Button("再試行") { controller.retryNotes() }
                                SettingsLink { Text("設定を開く") }
                            }
                        }
                    }
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

    var body: some View {
        Text(message)
            .foregroundStyle(.tertiary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var message: String {
        switch status {
        case .waiting, .updating, .failed, .paused:
            "話した内容が整理されて、ここに箇条書きで増えていきます。"
        case .inactive, .notConfigured:
            "会議を開始すると、話した内容をここに整理します。"
        }
    }
}

private struct NotesList: View {
    let store: NotesStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(store.notes.topics) { topic in
                    TopicView(topic: topic, changedIDs: store.recentlyChangedIDs)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title)
                .font(.headline)
                .padding(.horizontal, 4)
                .background(highlight(changedIDs.contains(topic.id)))
            ForEach(topic.items) { item in
                NoteItemRow(item: item, isHighlighted: changedIDs.contains(item.id))
            }
        }
    }
}

private struct NoteItemRow: View {
    let item: NoteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindBadge(kind: item.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
