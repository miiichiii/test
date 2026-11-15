import AppKit
import LiveMinutesKit
import SwiftUI

/// 左ペイン。確定テキストは通常の色、未確定テキストは薄い色で、各行に開始時刻（録音経過時間）を付けて表示する。
struct TranscriptPane: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: headerTitle) {
                ExportMenu(controller: controller)
            }

            if let problem = controller.problem {
                ProblemBanner(problem: problem)
            }
            if let warning = controller.warning {
                Banner(message: warning.message, systemImage: "externaldrive.badge.exclamationmark")
            }
            if case .preparing(let progress?) = controller.state {
                ModelDownloadProgress(progress: progress)
            }

            TranscriptList(transcript: controller.transcript, isRecording: controller.state == .recording)
        }
    }

    private var headerTitle: String {
        if let title = controller.sessionMeta?.title {
            return "文字起こし — \(title)"
        }
        return "文字起こし"
    }
}

// MARK: - 一覧と自動スクロール

private struct TranscriptList: View {
    let transcript: TranscriptStore
    let isRecording: Bool

    /// 最下部からこの距離以内なら「最下部にいる」とみなす。未確定1行の高さより大きくする。
    private static let followThreshold: CGFloat = 60
    private static let bottomID = "transcript-bottom"

    @State private var position = ScrollPosition(edge: .bottom)
    /// 新しい行に合わせて最下部へ追従するか。利用者が上にスクロールすると止める
    @State private var isFollowing = true

    var body: some View {
        ScrollView {
            // 1つの Text にまとめると、未確定の更新のたびに全体を組み直して長時間で重くなるので、行ごとに分ける。
            // この View の body では store の値を読まず、確定行・未確定行・案内をそれぞれ子 View で読む
            // （未確定の更新で、確定行の一覧まで評価し直さないため）。
            LazyVStack(alignment: .leading, spacing: 8) {
                SegmentRows(transcript: transcript, onAppend: scrollToBottomIfFollowing)
                VolatileRow(transcript: transcript, onChange: scrollToBottomIfFollowing)
                EmptyTranscriptHint(transcript: transcript, isRecording: isRecording)
                // 最下部の目印。LazyVStack では未生成の行の高さが推定なので、端ではなくこの目印へスクロールする。
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offsetY: geometry.contentOffset.y,
                distanceToBottom: max(geometry.contentSize.height - geometry.visibleRect.maxY, 0)
            )
        } action: { old, new in
            if new.distanceToBottom <= Self.followThreshold {
                isFollowing = true
            } else if new.offsetY < old.offsetY {
                // 上にスクロールして最下部から離れたときだけ止める。行が増えただけ（位置が変わらない）なら止めない。
                isFollowing = false
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isFollowing {
                Button {
                    isFollowing = true
                    position.scrollTo(id: Self.bottomID, anchor: .bottom)
                } label: {
                    Label("最新へ", systemImage: "arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(12)
                .help("最新の発言まで移動する")
            }
        }
    }

    private func scrollToBottomIfFollowing() {
        guard isFollowing else { return }
        // アニメーションを付けると、途中の位置で「上にスクロールした」と誤判定するので付けない。
        position.scrollTo(id: Self.bottomID, anchor: .bottom)
    }
}

/// 確定行の一覧。行が増えたら知らせる。
private struct SegmentRows: View {
    let transcript: TranscriptStore
    let onAppend: () -> Void

    var body: some View {
        ForEach(transcript.segments) { segment in
            SegmentRow(segment: segment)
        }
        .onChange(of: transcript.segments.count) { onAppend() }
    }
}

/// 未確定の行。変わったら知らせる。
private struct VolatileRow: View {
    let transcript: TranscriptStore
    let onChange: () -> Void

    var body: some View {
        let text = transcript.volatileText
        Group {
            if !text.isEmpty {
                Text(text)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SegmentRow.timeWidth + SegmentRow.spacing)
                    .accessibilityLabel("未確定: \(text)")
            }
        }
        .onChange(of: text) { onChange() }
    }
}

/// まだ何も文字になっていないときの案内。
private struct EmptyTranscriptHint: View {
    let transcript: TranscriptStore
    let isRecording: Bool

    var body: some View {
        if transcript.segments.isEmpty, transcript.volatileText.isEmpty {
            Text(isRecording ? "話すと、ここに文字が表示されます。" : "「開始」を押すと文字起こしを始めます。")
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ScrollMetrics: Equatable {
    let offsetY: CGFloat
    let distanceToBottom: CGFloat
}

private struct SegmentRow: View {
    static let timeWidth: CGFloat = 64
    static let spacing: CGFloat = 8

    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
            Text(ElapsedTimeFormat.string(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.timeWidth, alignment: .leading)
                .accessibilityLabel("開始 \(ElapsedTimeFormat.string(segment.start))")
            Text(segment.text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 書き出し

private struct ExportMenu: View {
    let controller: SessionController
    @State private var exportDocument: TranscriptExportDocument?
    @State private var exportFormat: TranscriptExportFormat = .plainText
    @State private var isExporterPresented = false
    @State private var isExportFailed = false

    var body: some View {
        Menu {
            Button("文字起こしをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text(for: .plainText), forType: .string)
            }
            Divider()
            Button("テキストとして保存…") { export(.plainText) }
            Button("Markdown として保存…") { export(.markdown) }
        } label: {
            Label("書き出し", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(controller.transcript.segments.isEmpty)
        .help("文字起こしをコピー・保存する（確定した部分だけ）")
        // fileExporter を形式ごとに付けると片方しか効かないことがあるので、1つにまとめて形式を切り替える。
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: exportFormat.contentType,
            defaultFilename: TranscriptExporter.suggestedFileName(title: title)
        ) { result in
            exportDocument = nil
            if case .failure = result {
                isExportFailed = true
            }
        }
        .alert("保存できませんでした", isPresented: $isExportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("保存先や空き容量を確認して、もう一度保存してください。")
        }
    }

    private var title: String {
        controller.sessionMeta?.title ?? "文字起こし"
    }

    /// 書き出しは確定セグメントだけから作る（画面の確定部分と一致させる）。
    private func text(for format: TranscriptExportFormat) -> String {
        let segments = controller.transcript.segments
        let startedAt = controller.sessionMeta?.startedAt
        switch format {
        case .plainText:
            return TranscriptExporter.plainText(title: title, startedAt: startedAt, segments: segments)
        case .markdown:
            return TranscriptExporter.markdown(title: title, startedAt: startedAt, segments: segments)
        }
    }

    private func export(_ format: TranscriptExportFormat) {
        exportFormat = format
        exportDocument = TranscriptExportDocument(text: text(for: format))
        isExporterPresented = true
    }
}

// MARK: - 案内

/// 権限がない場合などの案内。
private struct ProblemBanner: View {
    let problem: SessionController.Problem
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

private struct Banner: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12))
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
