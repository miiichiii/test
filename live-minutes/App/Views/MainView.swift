import LiveMinutesKit
import SwiftUI

/// メイン画面。左に文字起こし、右にノートを並べる。
struct MainView: View {
    let model: LiveTranscriptionModel

    var body: some View {
        HSplitView {
            TranscriptPane(model: model)
                .paneFrame()
            PaneView(title: "ノート")
                .paneFrame()
        }
        .frame(minHeight: 320)
        .navigationSubtitle("バージョン \(LiveMinutesInfo.version)")
        .toolbar {
            RecordingToolbar(model: model)
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

struct PaneHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
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
