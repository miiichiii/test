import LiveMinutesKit
import SwiftUI

/// 左ペイン。確定テキストは通常の色、未確定テキストは薄い色で表示する。
struct TranscriptPane: View {
    let model: LiveTranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "文字起こし")

            if let problem = model.problem {
                ProblemBanner(problem: problem)
            }
            if case .preparing(let progress?) = model.state {
                ModelDownloadProgress(progress: progress)
            }

            TranscriptList(transcript: model.transcript, isRecording: model.state == .recording)
        }
    }
}

private struct TranscriptList: View {
    let transcript: TranscriptBuffer
    let isRecording: Bool

    var body: some View {
        ScrollView {
            // 1つの Text にまとめると、未確定の更新のたびに全体を組み直して長時間で重くなるので、行ごとに分ける。
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(transcript.segments) { segment in
                    Text(segment.text)
                        .foregroundStyle(.primary)
                }
                if !transcript.volatileText.isEmpty {
                    Text(transcript.volatileText)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("未確定: \(transcript.volatileText)")
                }
                if transcript.segments.isEmpty, transcript.volatileText.isEmpty {
                    Text(isRecording ? "話すと、ここに文字が表示されます。" : "「開始」を押すと文字起こしを始めます。")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
        // 新しい行が来たら最下部を表示し続ける。
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

/// 権限がない場合などの案内。
private struct ProblemBanner: View {
    let problem: LiveTranscriptionModel.Problem
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            if problem == .microphoneDenied {
                Button("システム設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        openURL(url)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

private struct ModelDownloadProgress: View {
    let progress: Double

    var body: some View {
        ProgressView(value: progress) {
            Text("音声認識モデルをダウンロードしています… \(Int(progress * 100))%")
        }
        .padding(12)
    }
}
