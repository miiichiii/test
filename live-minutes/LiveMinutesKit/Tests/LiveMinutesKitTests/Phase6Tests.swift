import Foundation
import Testing
@testable import LiveMinutesKit

/// Phase 6（仕上げ）のテスト。実際の API やマイクは使わない。
@Suite("長い会議の入力の絞り込み")
struct NotesTrimmingTests {
    static func bigNotes(topics: Int, itemsPerTopic: Int = 10) -> Notes {
        Notes(topics: (1...topics).map { topicNumber in
            Topic(id: "t\(topicNumber)", title: "議題\(topicNumber)", items: (1...itemsPerTopic).map { itemNumber in
                NoteItem(id: "i\(topicNumber)-\(itemNumber)", kind: .point, text: String(repeating: "長い要点の本文", count: 6))
            })
        })
    }

    @Test("ノートが小さいうちは、全部の項目を送る（items_omitted を付けない）")
    func smallNotesUntouched() throws {
        let payload = LiveNotesInput.NotesPayload.trimmed(Self.bigNotes(topics: 2, itemsPerTopic: 2))
        #expect(payload.topics.allSatisfy { !$0.itemsOmitted && !$0.items.isEmpty })
        let json = try LiveNotesInput(title: "会", glossary: [], notes: Self.bigNotes(topics: 2, itemsPerTopic: 2), recentContext: "", segments: []).jsonString()
        #expect(!json.contains("items_omitted"))
    }

    @Test("6,000 文字を超えたら、直近3トピックだけ項目を送り、それより前はタイトルだけにする")
    func largeNotesTrimmed() throws {
        let notes = Self.bigNotes(topics: 6)
        let payload = LiveNotesInput.NotesPayload.trimmed(notes)
        #expect(payload.topics.map(\.title) == notes.topics.map(\.title))
        #expect(payload.topics.prefix(3).allSatisfy { $0.itemsOmitted && $0.items.isEmpty })
        #expect(payload.topics.suffix(3).allSatisfy { !$0.itemsOmitted && $0.items.count == 10 })

        let json = try LiveNotesInput(title: "会", glossary: [], notes: notes, recentContext: "", segments: []).jsonString()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let topics = try #require((object["notes"] as? [String: Any])?["topics"] as? [[String: Any]])
        #expect(topics.first?["items_omitted"] as? Bool == true)
        #expect(topics.last?["items_omitted"] == nil)
    }

    @Test("省いたトピックへの add_item も適用できる（ノートの正は全体なので）")
    func addItemToOmittedTopic() {
        let notes = Self.bigNotes(topics: 6)
        let result = NotesReducer.apply([NotesOp(op: .addItem, topicID: "t1", kind: .decision, text: "決まった")], to: notes)
        #expect(result.notes.topics[0].items.count == 11)
        #expect(result.ignored.isEmpty)
    }

    @Test("トピックが3つ以下なら、大きくても絞らない")
    func fewTopicsNotTrimmed() {
        let payload = LiveNotesInput.NotesPayload.trimmed(Self.bigNotes(topics: 3, itemsPerTopic: 40))
        #expect(payload.topics.allSatisfy { !$0.itemsOmitted })
    }
}

@Suite("手で直したノートの項目")
struct PinnedItemTests {
    static let notes = Notes(topics: [Topic(id: "t1", title: "議題", items: [
        NoteItem(id: "i1", kind: .point, text: "手で直した", isPinned: true),
        NoteItem(id: "i2", kind: .point, text: "自動"),
    ])])

    @Test("固定した項目への update_item と remove_item は無視する。固定していない項目は変わる")
    func reducerIgnoresPinned() {
        let result = NotesReducer.apply([
            NotesOp(op: .updateItem, itemID: "i1", text: "上書き"),
            NotesOp(op: .removeItem, itemID: "i1"),
            NotesOp(op: .updateItem, itemID: "i2", text: "更新"),
        ], to: Self.notes)
        #expect(result.notes.topics[0].items.map(\.text) == ["手で直した", "更新"])
        #expect(result.ignored.map(\.reason) == [.pinnedItem, .pinnedItem])
    }

    @Test("Phase 5 までの notes.json（is_pinned がない）も読め、書くと is_pinned が入る")
    func decodesOldNotes() throws {
        let old = #"{"topics":[{"id":"t1","title":"議題","items":[{"id":"i1","kind":"point","text":"本文"}]}],"nextTopicNumber":2,"nextItemNumber":2}"#
        let notes = try JSONDecoder().decode(Notes.self, from: Data(old.utf8))
        #expect(notes.topics[0].items[0].isPinned == false)
        let encoded = String(decoding: try JSONEncoder().encode(Self.notes), as: UTF8.self)
        #expect(encoded.contains(#""is_pinned":true"#))
    }
}

@MainActor
@Suite("ライブ更新の仕上げ（オフライン・手で直す）")
struct NotesPolishTests {
    let clock = ManualNotesClock()
    let client = ControlledLLMClient()
    let store = NotesStore(highlightDuration: .seconds(30))
    let recorder = NotesRecorder()

    private func makeEngine() throws -> NotesEngine {
        let store = self.store
        let recorder = self.recorder
        return NotesEngine(
            client: client,
            configuration: NotesEngine.Configuration(meetingTitle: "会議", glossary: [], minCharacters: 120, maxInterval: 20, minInterval: 8),
            clock: clock,
            systemPrompt: "prompt",
            schema: try LLMResources.notesOpsSchema(),
            modelSelection: { NotesEngine.ModelSelection(model: "m", reasoningEffort: nil) },
            persist: { await recorder.record($0) },
            report: { store.receive($0) }
        )
    }

    @Test("ネットワークにつながらないときはオフラインと出し、再試行で（つながったら）すぐに送り直す")
    func offlineAndRecover() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, error: .network)
        await waitUntil { store.status == .offline }
        #expect(await engine.isHalted == false)

        // つながった（SessionController.networkDidBecomeAvailable から retryNow）。20秒を待たずに送る。
        await engine.retryNow()
        await waitUntil { await client.requests.count == 2 }
        await client.respond(1, ops: [])
        await waitUntil { store.status == .waiting }
    }

    @Test("タイムアウトはオフラインと出さない（つながってはいるため）")
    func timeoutIsNotOffline() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, error: .timeout)
        await waitUntil { await !engine.isInFlight }
        #expect(store.status == .failed(message: LLMError.timeout.localizedDescription, needsRetry: false))
    }

    @Test("手で直すと固定して保存し、画面に反映する。後のモデルの更新では書き換えない。削除もできる")
    func manualEdit() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, ops: [
            NotesOp(op: .addTopic, topicID: "new-1", title: "議題"),
            NotesOp(op: .addItem, topicID: "new-1", kind: .point, text: "誤った文"),
            NotesOp(op: .addItem, topicID: "new-1", kind: .point, text: "消す文"),
        ])
        await waitUntil { store.notes.topics.first?.items.count == 2 }
        let ids = store.notes.topics[0].items.map(\.id)

        await engine.editItem(id: ids[0], text: "  正しい文  ")
        #expect(store.notes.topics[0].items[0].text == "正しい文")
        #expect(store.notes.topics[0].items[0].isPinned)
        #expect(await recorder.saved.last?.topics[0].items[0].text == "正しい文")

        await engine.deleteItem(id: ids[1])
        #expect(store.notes.topics[0].items.map(\.id) == [ids[0]])

        await engine.add(segment(characters: 130, at: 30))
        clock.advance(by: 20)
        await waitUntil { await client.requests.count == 2 }
        await client.respond(1, ops: [NotesOp(op: .updateItem, itemID: ids[0], text: "モデルの上書き")])
        await waitUntil { await !engine.isInFlight }
        #expect(store.notes.topics[0].items[0].text == "正しい文")
        await engine.abort()
    }
}

@Suite("用語")
struct GlossaryTests {
    @Test("入力欄の1行に1つ。前後の空白・空行・重複を除く")
    func parse() {
        #expect(AppSettings.glossaryTerms(from: " LiveMinutes \n\n佐藤\nLiveMinutes\n  \nSol") == ["LiveMinutes", "佐藤", "Sol"])
        #expect(AppSettings.glossaryTerms(from: "").isEmpty)
    }
}

@MainActor
final class FakeSleepPreventer: SleepPreventing {
    private(set) var history: [Bool] = []
    var isPreventing: Bool { history.last ?? false }

    func setPreventsSleep(_ prevents: Bool) {
        if history.last != prevents { history.append(prevents) }
    }
}

@MainActor
@Suite("録音中のスリープ防止")
struct SleepPreventionTests {
    let source = FakeAudioSource(chunks: [])
    let clock = FakeClock()

    @Test("録音中だけスリープを止め、一時停止・停止で解除する")
    func preventsWhileRecording() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let sleep = FakeSleepPreventer()
        let controller = SessionController(
            engine: ScriptedEngine(eventsPerStart: [[], []]),
            source: source,
            permission: FixedPermission(granted: true),
            repository: SessionRepository(rootDirectory: dir.url),
            clock: clock,
            sleepPreventer: sleep
        )
        #expect(controller.canStart)
        await controller.start()
        #expect(sleep.isPreventing)
        #expect(controller.canPause && controller.canStop && !controller.canStart)
        await controller.pause()
        #expect(!sleep.isPreventing)
        #expect(controller.canResume)
        await controller.resume()
        #expect(sleep.isPreventing)
        await controller.stop()
        #expect(!sleep.isPreventing)
        #expect(controller.canStart)
    }

    @Test("認識が失敗して終わったときも、解除する")
    func releasesOnFailure() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let sleep = FakeSleepPreventer()
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let controller = SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: SessionRepository(rootDirectory: dir.url),
            clock: clock,
            sleepPreventer: sleep
        )
        await controller.start()
        #expect(sleep.isPreventing)
        await engine.failDuringRecording(TranscriptionError.recognitionEnded)
        await waitUntil { controller.state == .finished }
        #expect(!sleep.isPreventing)
    }
}
