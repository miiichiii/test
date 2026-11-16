import LiveMinutesKit
import SwiftUI

/// メイン画面。左のサイドバーに今の会議と過去の会議、右に中身を出す。
/// 録音中は、左に文字起こし、右にノートを並べる。会議が終わったら、議事録 / ノート / 文字起こし を切り替えて見られる。
struct MainView: View {
    let controller: SessionController
    let settings: AppSettings
    let history: SessionHistory
    @State private var isStartSheetPresented = false
    @State private var selection: SidebarItem = .current

    var body: some View {
        NavigationSplitView {
            SessionSidebar(
                history: history,
                currentSessionID: controller.sessionMeta?.id,
                isLocked: isSessionLive,
                selection: $selection
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .frame(minHeight: 320)
        .task { await history.refresh() }
        // 会議が終わったら、一覧に足す。
        .onChange(of: controller.state) { _, newState in
            if newState == .finished { Task { await history.refresh() } }
            // 録音中は過去の会議に切り替えられない（録音を止めないため）。
            if isSessionLive { selection = .current }
        }
        .onChange(of: selection) { _, newSelection in
            switch newSelection {
            case .current:
                history.close()
            case .past(let id):
                Task { await history.open(id) }
            }
        }
        .navigationSubtitle("バージョン \(LiveMinutesInfo.version)")
        .toolbar {
            RecordingToolbar(controller: controller) {
                isStartSheetPresented = true
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定を開く")
            }
        }
        .sheet(isPresented: $isStartSheetPresented) {
            StartSessionSheet { title in
                isStartSheetPresented = false
                Task { await controller.start(title: title) }
            } onCancel: {
                isStartSheetPresented = false
            }
        }
    }
}

extension MainView {
    /// 会議が進んでいる間（準備中・録音中・一時停止中・確定中）。この間は過去の会議を開けない
    private var isSessionLive: Bool {
        switch controller.state {
        case .preparing, .recording, .paused, .finishing: true
        case .idle, .finished: false
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .past:
            if let detail = history.detail {
                SessionDetailView(
                    title: detail.meta.title,
                    startedAt: detail.meta.startedAt,
                    minutes: history.minutes,
                    notes: detail.notes,
                    segments: detail.segments,
                    canRegenerate: !isSessionLive,
                    onRegenerate: { Task { await history.regenerateMinutes() } },
                    onCancel: { history.minutes.cancel() },
                    onDelete: { Task { try? await history.delete(detail.meta.id); selection = .current } }
                )
            } else {
                ContentUnavailableView("会議を開けませんでした", systemImage: "exclamationmark.triangle")
            }
        case .current:
            if showsCurrentSummary, let meta = controller.sessionMeta {
                SessionDetailView(
                    title: meta.title,
                    startedAt: meta.startedAt,
                    minutes: controller.minutes,
                    notes: controller.notes.notes,
                    segments: controller.transcript.segments,
                    canRegenerate: controller.state == .finished,
                    onRegenerate: { Task { await controller.regenerateMinutes() } },
                    onCancel: { controller.cancelMinutes() },
                    onDelete: nil
                )
            } else {
                HSplitView {
                    TranscriptPane(controller: controller)
                        .paneFrame()
                    NotesPane(controller: controller, authMethod: settings.authMethod)
                        .paneFrame()
                }
            }
        }
    }

    /// 終わった今の会議は、議事録 / ノート / 文字起こし の切り替えで見せる（議事録の生成中も）
    private var showsCurrentSummary: Bool {
        controller.state == .finished || (controller.state == .finishing && controller.minutes.isGenerating)
    }
}

struct PaneHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                accessory
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
        }
    }
}

extension View {
    func paneFrame() -> some View {
        frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
