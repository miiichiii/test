import AVFAudio
import Foundation
import Testing
@testable import LiveMinutesKit

/// 実機の音声認識で `AppleSpeechEngine` を通しで動かす。マイクは使わず、音声ファイルを `FakeAudioSource` で流す。
///
/// 端末に日本語の音声認識モデルが必要なので、既定では実行しない。日本語の音声ファイルを用意して、
/// 環境変数 `LIVEMINUTES_SPEECH_AUDIO` にそのパスを入れたときだけ動く。例:
///
///     say -v Eddy -o /tmp/sample.aiff "来週の水曜日にリリースを延期します"
///     LIVEMINUTES_SPEECH_AUDIO=/tmp/sample.aiff swift test --filter AppleSpeechEngineIntegrationTests
@Suite(
    "AppleSpeechEngine（実機の音声認識）",
    .enabled(if: ProcessInfo.processInfo.environment["LIVEMINUTES_SPEECH_AUDIO"] != nil)
)
struct AppleSpeechEngineIntegrationTests {
    @Test("音声ファイルを流すと未確定と確定のイベントが届き、停止で最後まで確定する。2回目の開始もできる")
    func transcribesAudioFile() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LIVEMINUTES_SPEECH_AUDIO"])
        let engine = AppleSpeechEngine()
        try await engine.prepare(locale: Locale(identifier: "ja-JP")) { _ in }

        let analyzerFormat = try #require(await engine.preparedAudioFormat)
        let chunks = try Self.loadChunks(path: path, outputFormat: analyzerFormat)
        #expect(!chunks.isEmpty)

        for _ in 1...2 {
            let source = FakeAudioSource(chunks: chunks)
            let events = try await engine.start(source: source)
            let collector = Task {
                var volatileCount = 0
                var finals: [TranscriptSegment] = []
                for try await event in events {
                    switch event {
                    case .volatile: volatileCount += 1
                    case .final(let segment): finals.append(segment)
                    }
                }
                return (volatileCount, finals)
            }
            // 音声はすべて流し込み済み。停止すると、残りの未確定分まで確定してからストリームが終わる。
            try await Task.sleep(for: .milliseconds(500))
            await engine.stop()

            let (volatileCount, finals) = try await collector.value
            #expect(volatileCount > 0)
            #expect(!finals.isEmpty)
            let text = finals.map(\.text).joined()
            #expect(text.contains("リリース"), "認識結果の文字数: \(text.count)")
            #expect(finals.allSatisfy { $0.end >= $0.start })
        }
    }

    /// 音声ファイルを 100ms ごとのバッファに分け、エンジンが求める形式に変換する。
    static func loadChunks(path: String, outputFormat: AVAudioFormat) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let converter = try StreamingAudioConverter(from: file.processingFormat, to: outputFormat)
        let framesPerChunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        var chunks: [AudioChunk] = []
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerChunk))
            try file.read(into: buffer, frameCount: framesPerChunk)
            if let converted = try converter.convert(buffer) {
                chunks.append(AudioChunk(buffer: converted))
            }
        }
        return chunks
    }
}
