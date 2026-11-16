import Foundation
import Synchronization
import Testing
@testable import LiveMinutesKit

/// 偽の議事録の生成。届いた入力を記録し、決めた差分を順に流す（実際の API は呼ばない）。
actor FakeMinutesGenerator: MinutesGenerating {
    var configured = true
    var chunks: [String] = ["# 会議 議事録\n", "\n## 決定事項\n", "- 金曜に出す\n"]
    /// この数の差分を流した後に失敗する（nil なら最後まで流す）
    var failAfter: Int?
    /// 差分の間に待つ（中止のテスト用）
    var delay: Duration = .zero
    private(set) var inputs: [String] = []

    func isConfigured() async -> Bool { configured }

    func minutesStream(input: String) async -> AsyncThrowingStream<String, any Error> {
        inputs.append(input)
        let chunks = self.chunks
        let failAfter = self.failAfter
        let delay = self.delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, chunk) in chunks.enumerated() {
                    if let failAfter, index >= failAfter {
                        continuation.finish(throwing: LLMError.network)
                        return
                    }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func set(configured: Bool? = nil, chunks: [String]? = nil, failAfter: Int?? = nil, delay: Duration? = nil) {
        if let configured { self.configured = configured }
        if let chunks { self.chunks = chunks }
        if let failAfter { self.failAfter = failAfter }
        if let delay { self.delay = delay }
    }
}

@Suite("議事録の入力")
struct MinutesInputTests {
    @Test("入力の JSON に、会議・文字起こし全文・ノートが入る（キーは meeting → notes → transcript の順）")
    func input() throws {
        var meta = SessionMeta(title: "週次定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        meta.duration = 3725
        let notes = Notes(topics: [Topic(id: "t1", title: "リリース", items: [NoteItem(id: "i1", kind: .decision, text: "金曜に出す", owner: "佐藤")])])
        let segments = [segment("おはようございます", at: 0), segment("金曜に出しましょう", at: 65)]
        let json = try MinutesInput(meta: meta, glossary: ["LiveMinutes"], notes: notes, segments: segments, timeZone: TimeZone(identifier: "Asia/Tokyo")!).jsonString()

        #expect(json.hasPrefix(#"{"meeting":"#))
        let meetingIndex = try #require(json.range(of: #""meeting""#)).lowerBound
        let notesIndex = try #require(json.range(of: #""notes""#)).lowerBound
        let transcriptIndex = try #require(json.range(of: #""transcript""#)).lowerBound
        #expect(meetingIndex < notesIndex && notesIndex < transcriptIndex)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let meeting = try #require(object["meeting"] as? [String: Any])
        #expect(meeting["title"] as? String == "週次定例")
        #expect(meeting["started_at"] as? String == "2027-01-15 17:00")
        #expect(meeting["duration"] as? String == "01:02:05")
        #expect(meeting["glossary"] as? [String] == ["LiveMinutes"])
        let transcript = try #require(object["transcript"] as? [[String: Any]])
        #expect(transcript.map { $0["text"] as? String } == ["おはようございます", "金曜に出しましょう"])
        #expect(transcript.map { $0["t"] as? String } == ["00:00:00", "00:01:05"])
        let topics = try #require((object["notes"] as? [String: Any])?["topics"] as? [[String: Any]])
        #expect(topics.first?["title"] as? String == "リリース")
        let item = try #require((topics.first?["items"] as? [[String: Any]])?.first)
        #expect(item["owner"] as? String == "佐藤")
        #expect(item["due"] is NSNull)
    }
}

@MainActor
@Suite("議事録の生成と保存")
struct MinutesStoreTests {
    let meta = SessionMeta(title: "会議", startedAt: Date(timeIntervalSince1970: 1_800_000_000))

    private func makeStore(_ generator: FakeMinutesGenerator?, dir: TemporaryDirectory) async throws -> (MinutesStore, SessionRepository) {
        let repository = SessionRepository(rootDirectory: dir.url)
        try await repository.createSession(meta)
        return (MinutesStore(generator: generator, repository: repository), repository)
    }

    @Test("差分を届いた順につなぎ、完了したら minutes.md に保存する")
    func streamsAndSaves() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let generator = FakeMinutesGenerator()
        let (store, repository) = try await makeStore(generator, dir: dir)

        await store.generate(meta: meta, segments: [segment("こんにちは")], notes: Notes(), glossary: [])
        #expect(store.state == .completed)
        #expect(store.text == "# 会議 議事録\n\n## 決定事項\n- 金曜に出す")
        #expect(try await repository.loadMinutes(id: meta.id) == store.text)
        #expect(await generator.inputs.first?.contains("こんにちは") == true)
    }

    @Test("途中で失敗したら保存せず、前に保存した議事録を残す")
    func failureKeepsPrevious() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let generator = FakeMinutesGenerator()
        let (store, repository) = try await makeStore(generator, dir: dir)

        await generator.set(failAfter: 1)
        await store.generate(meta: meta, segments: [segment("a")], notes: Notes(), glossary: [])
        #expect(try await repository.loadMinutes(id: meta.id) == nil)
        #expect(store.text.isEmpty)
        #expect(store.state == .failed(LLMError.network.localizedDescription))

        try await repository.writeMinutes("前の議事録", to: meta.id)
        await store.generate(meta: meta, segments: [segment("a")], notes: Notes(), glossary: [])
        #expect(try await repository.loadMinutes(id: meta.id) == "前の議事録")
        #expect(store.text == "前の議事録")
    }

    @Test("中止したら、途中までを保存しない")
    func cancelDoesNotSave() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let generator = FakeMinutesGenerator()
        await generator.set(delay: .milliseconds(200))
        let (store, repository) = try await makeStore(generator, dir: dir)

        let generating = Task { await store.generate(meta: meta, segments: [segment("a")], notes: Notes(), glossary: []) }
        await waitUntil { store.isGenerating }
        store.cancel()
        await generating.value
        #expect(try await repository.loadMinutes(id: meta.id) == nil)
        #expect(store.state == .failed("議事録の作成を中止しました。"))
    }

    @Test("文字起こしがない、接続が設定されていない、作る相手がない場合は送らない")
    func skips() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let generator = FakeMinutesGenerator()
        let (store, _) = try await makeStore(generator, dir: dir)

        await store.generate(meta: meta, segments: [], notes: Notes(), glossary: [])
        if case .skipped = store.state {} else { Issue.record("文字起こしがなければ作らない") }
        await generator.set(configured: false)
        await store.generate(meta: meta, segments: [segment("a")], notes: Notes(), glossary: [])
        if case .skipped = store.state {} else { Issue.record("未設定なら作らない") }
        #expect(await generator.inputs.isEmpty)

        let (noGenerator, _) = try await makeStore(nil, dir: try TemporaryDirectory())
        await noGenerator.generate(meta: meta, segments: [segment("a")], notes: Notes(), glossary: [])
        if case .skipped = noGenerator.state {} else { Issue.record("作る相手がなければ作らない") }
    }

    @Test("新しい会議でリセットしたら、止めた生成の結果で表示を書き換えない")
    func resetIgnoresStaleResult() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let generator = FakeMinutesGenerator()
        await generator.set(delay: .milliseconds(100))
        let (store, _) = try await makeStore(generator, dir: dir)

        let generating = Task { await store.generate(meta: meta, segments: [segment("a")], notes: Notes(), glossary: []) }
        await waitUntil { store.isGenerating }
        store.reset()
        await generating.value
        #expect(store.state == .idle)
        #expect(store.text.isEmpty)
    }
}

@Suite("セッションの一覧と削除")
struct SessionListTests {
    @Test("一覧は新しい順。meta.json がない・壊れている・名前が UUID でないフォルダがあっても失敗しない")
    func listSkipsBroken() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        let old = SessionMeta(title: "古い", startedAt: Date(timeIntervalSince1970: 1_000))
        let new = SessionMeta(title: "新しい", startedAt: Date(timeIntervalSince1970: 2_000))
        try await repository.createSession(old)
        try await repository.createSession(new)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dir.url.appending(path: UUID().uuidString), withIntermediateDirectories: true)
        let broken = dir.url.appending(path: UUID().uuidString)
        try fileManager.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{壊れた".utf8).write(to: broken.appending(path: "meta.json"))
        try fileManager.createDirectory(at: dir.url.appending(path: "not-a-session"), withIntermediateDirectories: true)
        try Data().write(to: dir.url.appending(path: "stray.txt"))

        #expect(await repository.listSessions().map(\.title) == ["新しい", "古い"])
        #expect(await SessionRepository(rootDirectory: dir.url.appending(path: "missing")).listSessions().isEmpty)
    }

    @Test("削除するとフォルダごと消え、一覧からも消える。議事録の読み書き")
    func deleteAndMinutes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        let meta = SessionMeta(title: "会議", startedAt: Date())
        try await repository.createSession(meta)
        try await repository.appendSegment(segment("a"), to: meta.id)

        #expect(try await repository.loadMinutes(id: meta.id) == nil)
        try await repository.writeMinutes("# 議事録", to: meta.id)
        #expect(try await repository.loadMinutes(id: meta.id) == "# 議事録")

        try await repository.deleteSession(id: meta.id)
        #expect(FileManager.default.fileExists(atPath: repository.directory(for: meta.id).path(percentEncoded: false)) == false)
        #expect(await repository.listSessions().isEmpty)
        // もう一度消しても失敗しない。
        try await repository.deleteSession(id: meta.id)
    }
}

@MainActor
@Suite("過去のセッション（サイドバー）")
struct SessionHistoryTests {
    @Test("一覧を読み、開くと文字起こし・ノート・議事録を読み込む。作り直しと削除")
    func openRegenerateDelete() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let repository = SessionRepository(rootDirectory: dir.url)
        var meta = SessionMeta(title: "過去の会議", startedAt: Date())
        meta.status = .finished
        try await repository.createSession(meta)
        try await repository.appendSegment(segment("決めましょう"), to: meta.id)
        try await repository.writeNotes(Notes(topics: [Topic(id: "t1", title: "議題")]), to: meta.id)
        try await repository.writeMinutes("# 前の議事録", to: meta.id)
        await repository.closeTranscript(for: meta.id)

        let generator = FakeMinutesGenerator()
        let history = SessionHistory(repository: repository, minutesGenerator: generator)
        await history.refresh()
        #expect(history.sessions.map(\.id) == [meta.id])

        await history.open(meta.id)
        #expect(history.detail?.segments.map(\.text) == ["決めましょう"])
        #expect(history.detail?.notes.topics.map(\.title) == ["議題"])
        #expect(history.minutes.text == "# 前の議事録")
        #expect(history.minutes.state == .completed)

        await history.regenerateMinutes()
        #expect(history.minutes.text.hasPrefix("# 会議 議事録"))
        #expect(try await repository.loadMinutes(id: meta.id) == history.minutes.text)

        try await history.delete(meta.id)
        #expect(history.detail == nil)
        #expect(history.sessions.isEmpty)
    }
}
