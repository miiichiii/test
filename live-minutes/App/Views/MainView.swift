import LiveMinutesKit
import SwiftUI

/// メイン画面。左に文字起こし、右にノートを並べる。
struct MainView: View {
    var body: some View {
        HSplitView {
            PaneView(title: "文字起こし")
            PaneView(title: "ノート")
        }
        .frame(minHeight: 320)
        .navigationSubtitle("バージョン \(LiveMinutesInfo.version)")
    }
}

/// 見出しと空の領域だけを持つペイン。中身は後のフェーズで入れる。
private struct PaneView: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            Color.clear
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    MainView()
        .frame(width: 960, height: 600)
}
