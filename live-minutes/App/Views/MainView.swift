import LiveMinutesKit
import SwiftUI

/// メイン画面。左に文字起こし、右にノートを並べる。
struct MainView: View {
    let controller: SessionController
    @State private var isStartSheetPresented = false

    var body: some View {
        HSplitView {
            TranscriptPane(controller: controller)
                .paneFrame()
            PaneView(title: "ノート")
                .paneFrame()
        }
        .frame(minHeight: 320)
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

/// 見出しと空の領域だけを持つペイン。中身は後のフェーズで入れる。
private struct PaneView: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title)
            Color.clear
        }
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
