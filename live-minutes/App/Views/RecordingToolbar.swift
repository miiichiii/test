import LiveMinutesKit
import SwiftUI

/// ツールバー: 開始・停止、状態、入力レベル。
struct RecordingToolbar: ToolbarContent {
    let model: LiveTranscriptionModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            StatusLabel(state: model.state)
            LevelMeter(model: model)

            Button {
                Task { await model.start() }
            } label: {
                Label("開始", systemImage: "record.circle")
            }
            .disabled(model.state != .idle)
            .help("文字起こしを開始する")

            Button {
                Task { await model.stop() }
            } label: {
                Label("停止", systemImage: "stop.circle")
            }
            .disabled(model.state != .recording)
            .help("文字起こしを停止する")
        }
    }
}

private struct StatusLabel: View {
    let state: LiveTranscriptionModel.State

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .preparing:
            Text("準備中…").foregroundStyle(.secondary)
        case .recording:
            Label("録音中", systemImage: "waveform")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
        case .finishing:
            Text("確定中…").foregroundStyle(.secondary)
        }
    }
}

/// 入力レベルのメーター。レベルはこの View だけで読み、ほかの View を再描画させない。
private struct LevelMeter: View {
    let model: LiveTranscriptionModel

    var body: some View {
        let level = CGFloat(model.inputLevel)
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
            .accessibilityElement()
            .accessibilityLabel("入力レベル")
            .accessibilityValue("\(Int(level * 100))%")
    }
}
