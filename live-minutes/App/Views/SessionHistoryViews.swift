import AppKit
import LiveMinutesKit
import SwiftUI

/// サイドバーの項目
enum SidebarItem: Hashable {
    case current
    case past(UUID)
}

/// サイドバー: 今の会議と、過去の会議の一覧（新しい順）。削除は確認してから行う。
struct SessionSidebar: View {
    let history: SessionHistory
    /// 今の会議のセッション（過去の一覧からは除く）
    let currentSessionID: UUID?
    /// 録音中などは、過去の会議に切り替えられない
    let isLocked: Bool
    @Binding var selection: SidebarItem
    @State private var pendingDeletion: SessionMeta?

    var body: some View {
        List(selection: $selection) {
            Label("今の会議", systemImage: "waveform")
                .tag(SidebarItem.current)
            Section("過去の会議") {
                ForEach(pastSessions) { meta in
                    SessionRow(meta: meta)
                        .tag(SidebarItem.past(meta.id))
                        .selectionDisabled(isLocked)
                        .foregroundStyle(isLocked ? .secondary : .primary)
                        .contextMenu {
                            Button("削除…", role: .destructive) { pendingDeletion = meta }
                                .disabled(isLocked)
                        }
                }
                if pastSessions.isEmpty {
                    Text("まだありません").foregroundStyle(.tertiary)
                }
            }
        }
        .help(isLocked ? "会議の間は、過去の会議を開けません" : "")
        .confirmationDialog(
            "「\(pendingDeletion?.title ?? "")」を削除しますか？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { meta in
            Button("削除", role: .destructive) {
                Task {
                    if selection == .past(meta.id) { selection = .current }
                    try? await history.delete(meta.id)
                }
            }
        } message: { _ in
            Text("文字起こし・ノート・議事録が、この Mac から消えます。元に戻せません。")
        }
    }

    private var pastSessions: [SessionMeta] {
        history.sessions.filter { $0.id != currentSessionID }
    }
}

private struct SessionRow: View {
    let meta: SessionMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meta.title).lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        let date = meta.startedAt.formatted(date: .abbreviated, time: .shortened)
        // 異常終了で meta.json が recording のまま残ったもの。
        return meta.status == .recording ? "\(date)（途中で終了）" : date
    }
}

/// 終わった会議の中身: 議事録 / ノート / 文字起こし を切り替えて見る。
struct SessionDetailView: View {
    enum Tab: Hashable {
        case minutes, notes, transcript
    }

    let title: String
    let startedAt: Date
    let minutes: MinutesStore
    let notes: Notes
    let segments: [TranscriptSegment]
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onCancel: () -> Void
    /// 過去の会議だけ。今の会議では nil
    let onDelete: (() -> Void)?

    @State private var tab: Tab = .minutes
    @State private var isConfirmingDelete = false
    @State private var exportDocument: TranscriptExportDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("表示", selection: $tab) {
                    Text("議事録").tag(Tab.minutes)
                    Text("ノート").tag(Tab.notes)
                    Text("文字起こし").tag(Tab.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                if let onDelete {
                    Button("削除", role: .destructive) { isConfirmingDelete = true }
                        .confirmationDialog("「\(title)」を削除しますか？", isPresented: $isConfirmingDelete) {
                            Button("削除", role: .destructive, action: onDelete)
                        } message: {
                            Text("文字起こし・ノート・議事録が、この Mac から消えます。元に戻せません。")
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            switch tab {
            case .minutes:
                MinutesTab(
                    title: title,
                    minutes: minutes,
                    canRegenerate: canRegenerate,
                    onRegenerate: onRegenerate,
                    onCancel: onCancel,
                    onSave: { exportDocument = TranscriptExportDocument(text: minutes.text) }
                )
            case .notes:
                MarkdownTextTab(
                    text: notes.isEmpty ? "" : NotesExporter.markdown(title: title, notes: notes),
                    emptyMessage: "この会議のノートはありません。"
                )
            case .transcript:
                MarkdownTextTab(
                    text: segments.isEmpty ? "" : TranscriptExporter.plainText(title: title, startedAt: startedAt, segments: segments),
                    emptyMessage: "この会議の文字起こしはありません。"
                )
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: TranscriptExportFormat.markdown.contentType,
            defaultFilename: "\(TranscriptExporter.suggestedFileName(title: title))-議事録"
        ) { _ in exportDocument = nil }
    }
}

/// 議事録: 届いた分から順に表示する。コピー・保存・作り直し・中止。
private struct MinutesTab: View {
    let title: String
    let minutes: MinutesStore
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                status
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(minutes.text, forType: .string)
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
                .disabled(minutes.text.isEmpty || minutes.isGenerating)
                Button("Markdown で保存…", action: onSave)
                    .disabled(minutes.text.isEmpty || minutes.isGenerating)
                if minutes.isGenerating {
                    Button("中止", action: onCancel)
                } else {
                    Button(minutes.text.isEmpty ? "議事録を作る" : "作り直す", action: onRegenerate)
                        .disabled(!canRegenerate)
                        .help("文字起こし全文とノートを、議事録の仕上げ用のモデルに送って作り直します")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if minutes.text.isEmpty {
                Text(minutes.isGenerating ? "議事録を作っています…" : "議事録はまだありません。")
                    .foregroundStyle(.tertiary)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MarkdownTextTab(text: minutes.text, emptyMessage: "")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch minutes.state {
        case .idle, .completed:
            EmptyView()
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("議事録を作っています").foregroundStyle(.secondary)
            }
        case .failed(let message), .skipped(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Markdown のテキストを、行の形を保ったまま表示する（太字などの行内の書式だけを解釈する）。
private struct MarkdownTextTab: View {
    let text: String
    let emptyMessage: String

    var body: some View {
        if text.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.tertiary)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                Text(attributed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
