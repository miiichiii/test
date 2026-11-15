import Foundation
import Testing
@testable import LiveMinutesKit

@Suite("SessionRepository")
struct SessionRepositoryTests {
    private func transcriptURL(_ repository: SessionRepository, _ id: UUID) -> URL {
        repository.directory(for: id).appending(path: SessionRepository.transcriptFileName)
    }

    @Test("作成でフォルダと meta.json と空の transcript.jsonl ができ、meta を読み書きできる")
    func createAndMeta() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        var meta = SessionMeta(title: "週次定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000))

        try await repository.createSession(meta)
        #expect(try await repository.loadMeta(id: meta.id) == meta)
        #expect(try await repository.loadTranscript(id: meta.id).segments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: transcriptURL(repository, meta.id).path(percentEncoded: false)))

        meta.duration = 1234.5
        meta.status = .finished
        try await repository.writeMeta(meta)
        #expect(try await repository.loadMeta(id: meta.id) == meta)
    }

    @Test("追記したセグメントを順に読み込める")
    func appendAndLoad() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        let meta = SessionMeta(title: "t", startedAt: Date())
        try await repository.createSession(meta)

        let segments = [
            TranscriptSegment(start: 0, end: 1.5, text: "おはようございます"),
            TranscriptSegment(start: 1.5, end: 3, text: "改行を\n含む \"引用\" と / 記号"),
        ]
        for segment in segments {
            try await repository.appendSegment(segment, to: meta.id)
        }
        await repository.closeTranscript(for: meta.id)

        let result = try await repository.loadTranscript(id: meta.id)
        #expect(result.segments == segments)
        #expect(result.skippedLineCount == 0)
        // 1行1件になっている。
        let text = try String(contentsOf: transcriptURL(repository, meta.id), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test("最後の行がマルチバイト文字の途中で切れていても、読める行までを読み込む")
    func truncatedLastLine() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        let meta = SessionMeta(title: "t", startedAt: Date())
        try await repository.createSession(meta)
        let kept = TranscriptSegment(start: 0, end: 1, text: "ここまでは残る")
        try await repository.appendSegment(kept, to: meta.id)
        try await repository.appendSegment(TranscriptSegment(start: 1, end: 2, text: "日本語の途中で切れる"), to: meta.id)
        await repository.closeTranscript(for: meta.id)

        // 最後の行を「日」の UTF-8（3バイト）の途中で切る。
        let url = transcriptURL(repository, meta.id)
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A)
        let lastLine = try #require(lines.last)
        let marker = Data("日本語".utf8)
        let markerRange = try #require(Data(lastLine).range(of: marker))
        let cut = data.count - lastLine.count + markerRange.lowerBound + 1
        let truncated = data.prefix(cut)
        try truncated.write(to: url)
        #expect(String(data: truncated, encoding: .utf8) == nil)

        let result = try await repository.loadTranscript(id: meta.id)
        #expect(result.segments == [kept])
        #expect(result.skippedLineCount == 1)
    }

    @Test("途中で切れたファイルに追記するときは、改行を足してから書く")
    func appendAfterTruncation() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        let meta = SessionMeta(title: "t", startedAt: Date())
        try await repository.createSession(meta)
        let kept = TranscriptSegment(start: 0, end: 1, text: "残る")
        try await repository.appendSegment(kept, to: meta.id)
        await repository.closeTranscript(for: meta.id)

        let url = transcriptURL(repository, meta.id)
        var data = try Data(contentsOf: url)
        data.append(Data("{\"text\":\"切れ".utf8))
        try data.write(to: url)

        let added = TranscriptSegment(start: 2, end: 3, text: "続き")
        try await repository.appendSegment(added, to: meta.id)
        await repository.closeTranscript(for: meta.id)

        let result = try await repository.loadTranscript(id: meta.id)
        #expect(result.segments == [kept, added])
        #expect(result.skippedLineCount == 1)
    }

    @Test("既定の保存先は Application Support/LiveMinutes/sessions")
    func defaultRoot() {
        let path = SessionRepository.defaultRootDirectory.path(percentEncoded: false)
        #expect(path.hasSuffix("Application Support/LiveMinutes/sessions/") || path.hasSuffix("Application Support/LiveMinutes/sessions"))
    }
}

@Suite("書き出し")
struct TranscriptExporterTests {
    let segments = [
        TranscriptSegment(start: 5, end: 7, text: "おはようございます"),
        TranscriptSegment(start: 3725, end: 3730, text: "*強調* と # 見出し\nと改行"),
    ]

    @Test("経過時間は HH:MM:SS")
    func elapsedFormat() {
        #expect(ElapsedTimeFormat.string(0) == "00:00:00")
        #expect(ElapsedTimeFormat.string(59.9) == "00:00:59")
        #expect(ElapsedTimeFormat.string(3725) == "01:02:05")
        #expect(ElapsedTimeFormat.string(-3) == "00:00:00")
        #expect(ElapsedTimeFormat.string(.nan) == "00:00:00")
    }

    @Test("テキストは各行に開始時刻を付け、改行は空白にする")
    func plainText() {
        let text = TranscriptExporter.plainText(title: "週次定例", startedAt: nil, segments: segments)
        #expect(text == """
        週次定例

        [00:00:05] おはようございます
        [01:02:05] *強調* と # 見出し と改行

        """)
    }

    @Test("Markdown は見出しと箇条書きにし、記号をエスケープする")
    func markdown() {
        let text = TranscriptExporter.markdown(title: "週次定例", startedAt: nil, segments: segments)
        #expect(text == """
        # 週次定例

        ## 文字起こし

        - **00:00:05** おはようございます
        - **01:02:05** \\*強調\\* と \\# 見出し と改行

        """)
    }

    @Test("開始日時を入れると2行目に出る")
    func withStartDate() {
        let text = TranscriptExporter.plainText(title: "t", startedAt: Date(timeIntervalSince1970: 0), segments: [])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4)
        #expect(!lines[1].isEmpty)
    }

    @Test("ファイル名に使えない文字は置き換える")
    func fileName() {
        #expect(TranscriptExporter.suggestedFileName(title: "a/b:c") == "a-b-c")
        #expect(TranscriptExporter.suggestedFileName(title: "  ") == "文字起こし")
        #expect(TranscriptExporter.suggestedFileName(title: "..隠し") == "隠し")
        #expect(TranscriptExporter.suggestedFileName(title: String(repeating: "あ", count: 300)).count == 100)
    }
}
