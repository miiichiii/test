import Foundation
import Testing
@testable import LiveMinutesKit

/// NotesEngine のテスト。偽の時計と、応答を手で返す偽の LLMClient を使う（実際の API は呼ばない）。
@MainActor
@Suite("NotesEngine")
struct NotesEngineTests {
    let clock = ManualNotesClock()
    let client = ControlledLLMClient()
    // ハイライトが消えることは NotesStore のテストで確かめる。ここでは消える前に確かめられるよう長くする。
    let store = NotesStore(highlightDuration: .seconds(30))
    let recorder = NotesRecorder()
    let selection = ModelSelectionBox()
    static let prompt = "システムプロンプト（テスト）"

    private func makeEngine(
        title: String = "週次定例",
        glossary: [String] = ["LiveMinutes"],
        maxBatchCharacters: Int = 2000
    ) throws -> NotesEngine {
        let store = self.store
        let recorder = self.recorder
        let selection = self.selection
        return NotesEngine(
            client: client,
            configuration: NotesEngine.Configuration(
                meetingTitle: title,
                glossary: glossary,
                minCharacters: 120,
                maxInterval: 20,
                minInterval: 8,
                maxBatchCharacters: maxBatchCharacters
            ),
            clock: clock,
            systemPrompt: Self.prompt,
            schema: try LLMResources.notesOpsSchema(),
            modelSelection: { NotesEngine.ModelSelection(model: selection.model, reasoningEffort: selection.effort) },
            persist: { await recorder.record($0) },
            report: { store.receive($0) }
        )
    }

    private func requestCount() async -> Int {
        await client.requests.count
    }

    /// エンジンが落ち着く（予約・送信の判断を終える）まで少し待つ。
    private func settle(_ engine: NotesEngine) async {
        for _ in 0..<20 {
            await Task.yield()
        }
        _ = await engine.isInFlight
    }

    // MARK: - 送信の条件

    @Test("120字以上たまったら送る。ただし開始から8秒以内は送らない")
    func sendsAt120Characters() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 60, at: 1))
        await engine.add(segment(characters: 60, at: 2))
        await settle(engine)
        #expect(await requestCount() == 0)
        #expect(await engine.scheduledWakeAt == 1008)

        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        #expect(await client.sentTexts(0).count == 2)
    }

    @Test("120字に達していなくても、前回の完了から20秒たてば送る")
    func sendsAfter20Seconds() async throws {
        let engine = try makeEngine()
        await engine.add(segment("短い発言"))
        clock.advance(by: 8)
        await settle(engine)
        #expect(await requestCount() == 0)
        #expect(await engine.scheduledWakeAt == 1020)

        clock.advance(by: 12)
        await waitUntil { await requestCount() == 1 }
    }

    @Test("前回の完了から8秒以内は、120字を超えても送らない")
    func respectsMinimumInterval() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [])
        await waitUntil { await !engine.isInFlight }

        // 完了は 1008。直後に 200 字が来ても 1016 までは送らない。
        await engine.add(segment(characters: 200))
        await settle(engine)
        #expect(await requestCount() == 1)
        #expect(await engine.scheduledWakeAt == 1016)

        clock.advance(by: 7)
        await settle(engine)
        #expect(await requestCount() == 1)
        clock.advance(by: 1)
        await waitUntil { await requestCount() == 2 }
    }

    @Test("応答待ちの間に届いた発言は、次の1回にまとめて送る（同時に2本送らない）")
    func coalescesWhileInFlight() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }

        await engine.add(segment(characters: 100, at: 10))
        await engine.add(segment(characters: 100, at: 11))
        clock.advance(by: 30)
        await settle(engine)
        #expect(await requestCount() == 1)

        await client.respond(0, ops: [])
        await waitUntil { await !engine.isInFlight }
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 2 }
        #expect(await client.sentTexts(1).count == 2)
    }

    // MARK: - 失敗

    @Test("通信エラーで失敗したら同じ発言を残し、20秒たってから送り直す（120字以上でも8秒では送らない）")
    func retriesSameSegmentsAfterFailure() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        let firstTexts = await client.sentTexts(0)

        await client.respond(0, error: .network)
        await waitUntil { await !engine.isInFlight }
        #expect(store.status == .failed(message: LLMError.network.localizedDescription, needsRetry: false))
        #expect(await engine.pending.count == 1)

        await engine.add(segment(characters: 200, at: 20))
        clock.advance(by: 8)
        await settle(engine)
        #expect(await requestCount() == 1)

        clock.advance(by: 12)
        await waitUntil { await requestCount() == 2 }
        #expect(await client.sentTexts(1).prefix(1) == firstTexts.prefix(1))
        #expect(await client.sentTexts(1).count == 2)
    }

    @Test("キーの誤りなど直らない失敗では自動で送らず、再試行で再開する")
    func haltsOnPermanentFailure() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, error: .authentication)
        await waitUntil { await !engine.isInFlight }

        #expect(await engine.isHalted)
        #expect(store.status == .failed(message: LLMError.authentication.localizedDescription, needsRetry: true))
        clock.advance(by: 120)
        await settle(engine)
        #expect(await requestCount() == 1)

        await engine.retryNow()
        await waitUntil { await requestCount() == 2 }
        #expect(await engine.isHalted == false)
    }

    @Test("ChatGPT のプランのエラー: 使用量の上限や要ログインは止め、使用量を確かめられないだけなら送り直す", arguments: [
        (LLMError.usageLimitReached, true),
        (.chatGPTSignInRequired, true),
        (.chatGPTPlanNotGranted, true),
        (.planNotEligible(message: nil), true),
        (.unsupportedCapability(param: "text"), true),
        (.chatGPTUnauthorized, true),
        (.planUsageUnavailable, false),
    ])
    func chatGPTPlanFailureKinds(error: LLMError, halts: Bool) async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, error: error)
        await waitUntil { await !engine.isInFlight }

        #expect(await engine.isHalted == halts)
        #expect(store.status == .failed(message: error.localizedDescription, needsRetry: halts))
        // どちらの場合も、発言は捨てない。
        #expect(await engine.pending.count == 1)
    }

    @Test("止まっている間に一時停止をオン・オフしても、エラーと再試行の表示に戻る")
    func haltSurvivesPauseToggle() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, error: .authentication)
        await waitUntil { await !engine.isInFlight }

        await engine.setPaused(true)
        #expect(store.status == .paused)
        await engine.setPaused(false)
        #expect(store.status == .failed(message: LLMError.authentication.localizedDescription, needsRetry: true))

        await engine.add(segment(characters: 130))
        clock.advance(by: 60)
        await settle(engine)
        #expect(await requestCount() == 1)
    }

    @Test("止まっていないときの再試行は、通常の条件で判断する（余計に送らない）")
    func retryNowWhenNotHalted() async throws {
        let engine = try makeEngine()
        await engine.add(segment("短い"))
        await engine.retryNow()
        await settle(engine)
        #expect(await requestCount() == 0)
        #expect(await engine.scheduledWakeAt == 1020)
    }

    @Test("出力不正が2回続いたら、そのバッチを捨てて先へ進む")
    func dropsBatchAfterRepeatedContentFailures() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, error: .invalidOutput)
        await waitUntil { await !engine.isInFlight }
        #expect(await engine.pending.count == 1)

        clock.advance(by: 20)
        await waitUntil { await requestCount() == 2 }
        await client.respond(1, error: .invalidOutput)
        await waitUntil { await !engine.isInFlight }

        #expect(await engine.pending.isEmpty)
        #expect(store.hasDroppedSegments)
        #expect(store.status == .waiting)
        clock.advance(by: 60)
        await settle(engine)
        #expect(await requestCount() == 2)
    }

    @Test("応答の op が1件壊れていても、残りは適用する")
    func lossyOps() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        let json = #"{"ops":[{"op":"add_topic","topic_id":"new-1","item_id":null,"title":"議題","kind":null,"text":null,"owner":null,"due":null},{"op":"explode"}]}"#
        await client.respond(0, with: .success(Data(json.utf8)))
        await waitUntil { await !engine.isInFlight }
        #expect(store.notes.topics.map(\.title) == ["議題"])
    }

    // MARK: - 適用と保存

    @Test("応答の差分をノートに適用し、画面と notes.json に反映する")
    func appliesOps() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [
            NotesOp(op: .addTopic, topicID: "new-1", title: "リリース日程"),
            NotesOp(op: .addItem, topicID: "new-1", kind: .action, text: "告知文を直す", owner: "佐藤", due: "金曜"),
        ])
        await waitUntil { await !engine.isInFlight }

        #expect(store.notes.topics.first?.items.first?.owner == "佐藤")
        #expect(store.recentlyChangedIDs == ["t1", "i1"])
        #expect(store.status == .waiting)
        #expect(await recorder.saved.last == store.notes)
    }

    @Test("変化のない応答（空の ops）では notes.json を書かない")
    func skipsPersistWhenUnchanged() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [])
        await waitUntil { await !engine.isInFlight }
        #expect(await recorder.saved.isEmpty)
    }

    // MARK: - 入力

    @Test("入力 JSON は DESIGN.md §4.5 の例と同じ構造で、キーの順も設計書のとおり")
    func inputStructure() async throws {
        let engine = try makeEngine()
        await engine.add(segment("じゃあリリースは来週の水曜に延ばしましょう", at: 751))
        await engine.add(segment(characters: 120, at: 758))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [
            NotesOp(op: .addTopic, topicID: "new-1", title: "リリース日程"),
            NotesOp(op: .addItem, topicID: "new-1", kind: .point, text: "テストが2日遅れている"),
        ])
        await waitUntil { await !engine.isInFlight }

        await engine.add(segment(characters: 130, at: 800))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 2 }

        let first = parseJSON(await client.inputString(0))
        #expect(Set(first.keys) == ["meeting", "notes", "recent_context", "new_transcript"])
        let meeting = try #require(first["meeting"] as? [String: Any])
        #expect(meeting["title"] as? String == "週次定例")
        #expect(meeting["glossary"] as? [String] == ["LiveMinutes"])
        #expect((first["notes"] as? [String: Any])?["topics"] as? [Any] != nil)
        #expect(first["recent_context"] as? String == "")
        let lines = try #require(first["new_transcript"] as? [[String: Any]])
        #expect(lines.first?["t"] as? String == "00:12:31")
        #expect(lines.first?["text"] as? String == "じゃあリリースは来週の水曜に延ばしましょう")

        // 2回目は、適用したノート（採番カウンタは含めず、owner と due は null を明示）と、直前に送った発言を含む。
        let second = parseJSON(await client.inputString(1))
        let topics = try #require((second["notes"] as? [String: Any])?["topics"] as? [[String: Any]])
        #expect(topics.first?["id"] as? String == "t1")
        let item = try #require((topics.first?["items"] as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["id", "kind", "text", "owner", "due"])
        #expect(item["owner"] is NSNull)
        #expect((second["notes"] as? [String: Any])?["nextTopicNumber"] == nil)
        #expect((second["recent_context"] as? String)?.contains("じゃあリリースは") == true)

        // キーの順: meeting → notes → recent_context → new_transcript（毎回変わる部分を最後に置く）
        let raw = await client.requests[1].input
        let order = ["\"meeting\"", "\"notes\"", "\"recent_context\"", "\"new_transcript\""].compactMap { raw.range(of: $0)?.lowerBound }
        #expect(order.count == 4)
        #expect(order == order.sorted())
    }

    @Test("会議名・glossary・発言の引用符やバックスラッシュ、改行、U+2028 も、JSON として正しく送る")
    func inputEscaping() async throws {
        let tricky = "引用\"符\\と\n改行と\u{2028}区切り"
        let engine = try makeEngine(title: tricky, glossary: [tricky])
        await engine.add(segment(tricky))
        await engine.add(segment(characters: 120))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }

        let input = parseJSON(await client.inputString(0))
        let meeting = try #require(input["meeting"] as? [String: Any])
        #expect(meeting["title"] as? String == tricky)
        #expect(meeting["glossary"] as? [String] == [tricky])
        #expect(await client.sentTexts(0).first == tricky)
    }

    @Test("recent_context は送信に成功した発言を、末尾からセグメント単位で400字まで取る。1件で超えるときは末尾を切り出す")
    func recentContextLimit() async throws {
        let engine = try makeEngine()
        // 1回目: 250字と200字。2回目の recent_context には、後の200字だけが入る（250字を足すと400字を超える）。
        await engine.add(segment(String(repeating: "前", count: 250)))
        await engine.add(segment(String(repeating: "後", count: 200)))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [])
        await waitUntil { await !engine.isInFlight }

        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 2 }
        #expect(parseJSON(await client.inputString(1))["recent_context"] as? String == String(repeating: "後", count: 200))
        await client.respond(1, ops: [])
        await waitUntil { await !engine.isInFlight }

        // 1件で400字を超える発言は、その末尾400字だけ。
        await engine.add(segment(String(repeating: "長", count: 500)))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 3 }
        await client.respond(2, ops: [])
        await waitUntil { await !engine.isInFlight }
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 4 }
        #expect(parseJSON(await client.inputString(3))["recent_context"] as? String == String(repeating: "長", count: 400))
    }

    @Test("捨てたバッチは recent_context に入らない")
    func droppedBatchNotInContext() async throws {
        let engine = try makeEngine()
        await engine.add(segment("拒否される発言" + String(repeating: "x", count: 130)))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, error: .refusal("no"))
        await waitUntil { await !engine.isInFlight }
        clock.advance(by: 20)
        await waitUntil { await requestCount() == 2 }
        await client.respond(1, error: .refusal("no"))
        await waitUntil { await !engine.isInFlight }

        await engine.add(segment(characters: 130))
        clock.advance(by: 20)
        await waitUntil { await requestCount() == 3 }
        #expect(parseJSON(await client.inputString(2))["recent_context"] as? String == "")
    }

    @Test("システムプロンプトとスキーマはリクエストごとに同じ。モデルIDは送信のたびに読む")
    func stablePromptAndLiveModelSelection() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [])
        await waitUntil { await !engine.isInFlight }

        selection.model = "gpt-6-luna-new"
        selection.effort = nil
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 2 }

        let requests = await client.requests
        #expect(requests[0].instructions == Self.prompt)
        #expect(requests[1].instructions == requests[0].instructions)
        #expect(requests[1].schema == requests[0].schema)
        #expect(requests[0].schemaName == "notes_ops")
        #expect(requests[0].model == "gpt-6-luna")
        #expect(requests[0].reasoningEffort == "low")
        #expect(requests[1].model == "gpt-6-luna-new")
        #expect(requests[1].reasoningEffort == nil)
    }

    @Test("1回に送る量には上限があり、残りは次に回す")
    func batchLimit() async throws {
        let engine = try makeEngine(maxBatchCharacters: 300)
        for index in 0..<5 {
            await engine.add(segment(characters: 100, at: TimeInterval(index)))
        }
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        #expect(await client.sentTexts(0).count == 3)
        await client.respond(0, ops: [])
        await waitUntil { await !engine.isInFlight }
        #expect(await engine.pending.count == 2)
    }

    // MARK: - 一時停止

    @Test("一時停止をオンにすると未送信を捨て、オンの間は送らない。オフに戻しても捨てた分は送らない")
    func pauseDiscardsAndBlocks() async throws {
        let engine = try makeEngine()
        await engine.add(segment("機微な話の冒頭"))
        await engine.setPaused(true)
        #expect(await engine.pending.isEmpty)
        #expect(store.status == .paused)

        await engine.add(segment(characters: 200))
        clock.advance(by: 60)
        await settle(engine)
        #expect(await requestCount() == 0)

        await engine.setPaused(false)
        #expect(store.status == .waiting)
        clock.advance(by: 60)
        await settle(engine)
        #expect(await requestCount() == 0)

        await engine.add(segment(characters: 130))
        await waitUntil { await requestCount() == 1 }
        #expect(await client.sentTexts(0) == [String(repeating: "あ", count: 130)])
    }

    @Test("飛行中に一時停止しても、その応答は適用する。失敗して戻った分は捨てる")
    func pauseWhileInFlight() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await engine.setPaused(true)
        await client.respond(0, error: .network)
        await waitUntil { await !engine.isInFlight }

        #expect(await engine.pending.isEmpty)
        #expect(store.status == .paused)
    }

    // MARK: - 終了

    @Test("停止時は、条件に関係なく残りを送ってから終える")
    func finishFlushes() async throws {
        let engine = try makeEngine()
        await engine.add(segment("最後のひとこと"))
        let finishing = Task { await engine.finish(.flush(timeout: 15)) }
        await waitUntil { await requestCount() == 1 }
        await client.respond(0, ops: [NotesOp(op: .addTopic, topicID: "new-1", title: "まとめ")])
        await finishing.value

        #expect(store.notes.topics.map(\.title) == ["まとめ"])
        await engine.add(segment(characters: 300))
        clock.advance(by: 60)
        await settle(engine)
        #expect(await requestCount() == 1)
    }

    @Test("停止時は、飛行中の応答を待ってから残りを送る")
    func finishWaitsForInFlight() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await engine.add(segment("後から来た発言"))

        let finishing = Task { await engine.finish(.flush(timeout: 15)) }
        await settle(engine)
        #expect(await requestCount() == 1)
        await client.respond(0, ops: [])
        await waitUntil { await requestCount() == 2 }
        #expect(await client.sentTexts(1) == ["後から来た発言"])
        await client.respond(1, ops: [])
        await finishing.value
    }

    @Test("停止時の送信が上限時間を超えたら、打ち切って終える")
    func finishTimesOut() async throws {
        let engine = try makeEngine()
        await engine.add(segment("最後"))
        let finishing = Task { await engine.finish(.flush(timeout: 15)) }
        await waitUntil { await requestCount() == 1 }
        await waitUntil { clock.sleeperCount >= 1 }

        clock.advance(by: 15)
        await finishing.value
        #expect(await engine.isInFlight == false)
        // 送れなかった残りがあったことを知らせる。
        #expect(store.hasDroppedSegments)
        // 打ち切った応答が後から届いても、ノートは変わらない。
        await client.respond(0, ops: [NotesOp(op: .addTopic, topicID: "new-1", title: "遅れて届いた")])
        await settle(engine)
        #expect(store.notes.isEmpty)
    }

    @Test("一時停止中に停止したら、残りを送らない")
    func finishWhilePaused() async throws {
        let engine = try makeEngine()
        await engine.add(segment("機微な話"))
        await engine.setPaused(true)
        await engine.finish(.flush(timeout: 15))
        #expect(await requestCount() == 0)
        #expect(store.hasDroppedSegments == false)
    }

    @Test("abandon は送らずに終える。abort の後は何も送らない")
    func abandonAndAbort() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        await engine.finish(.abandon)
        clock.advance(by: 60)
        await settle(engine)
        #expect(await requestCount() == 0)

        let other = try makeEngine()
        await other.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await requestCount() == 1 }
        await other.abort()
        #expect(await other.isInFlight == false)
        await other.finish(.flush(timeout: 15))
        #expect(await requestCount() == 1)
    }
}

@Suite("NotesExporter")
struct NotesExporterTests {
    @Test("トピックを見出しに、種類をラベルで示し、ToDo に担当と期限を添える")
    func markdown() {
        let notes = Notes(topics: [
            Topic(id: "t1", title: "リリース日程", items: [
                NoteItem(id: "i1", kind: .decision, text: "来週水曜に延期"),
                NoteItem(id: "i2", kind: .action, text: "告知文を直す", owner: "佐藤", due: "金曜"),
            ]),
        ])
        #expect(NotesExporter.markdown(title: "週次定例", notes: notes) == """
        # 週次定例

        ## リリース日程

        - [決定] 来週水曜に延期
        - [ToDo] 告知文を直す（担当: 佐藤、期限: 金曜）

        """)
        #expect(NotesExporter.markdown(title: "t", notes: Notes()).contains("ノートはまだありません"))
    }
}

@Suite("CachingSecretStore")
struct CachingSecretStoreTests {
    /// 読み出しの回数を数える SecretStore。
    actor CountingStore: SecretStore {
        var key: String?
        private(set) var reads = 0

        init(key: String?) { self.key = key }

        func hasAPIKey() async -> Bool { key != nil }

        func readAPIKey() async throws -> String {
            reads += 1
            try await Task.sleep(for: .milliseconds(20))
            guard let key else { throw LLMError.missingAPIKey }
            return key
        }

        func saveAPIKey(_ key: String) async throws { self.key = key.trimmingCharacters(in: .whitespacesAndNewlines) }
        func deleteAPIKey() async throws { key = nil }
    }

    @Test("最初に読めたキーを持ち、同時の読み出しは1回にまとめる")
    func cachesAndCoalesces() async throws {
        let base = CountingStore(key: "test-key")
        let store = CachingSecretStore(base: base)
        async let first = store.readAPIKey()
        async let second = store.readAPIKey()
        #expect(try await [first, second] == ["test-key", "test-key"])
        #expect(try await store.readAPIKey() == "test-key")
        #expect(await base.reads == 1)
    }

    @Test("読み出しの途中で削除されたら、読んだ値をキャッシュしない")
    func deleteDuringRead() async throws {
        let base = CountingStore(key: "old-key")
        let store = CachingSecretStore(base: base)
        async let reading = store.readAPIKey()
        try await Task.sleep(for: .milliseconds(5))
        try await store.deleteAPIKey()
        _ = try? await reading
        await #expect(throws: LLMError.missingAPIKey) { try await store.readAPIKey() }
        #expect(await store.hasAPIKey() == false)
    }

    @Test("失敗はキャッシュしない。保存した値を持ち、削除と invalidate で捨てる")
    func saveDeleteInvalidate() async throws {
        let base = CountingStore(key: nil)
        let store = CachingSecretStore(base: base)
        await #expect(throws: LLMError.missingAPIKey) { try await store.readAPIKey() }

        try await store.saveAPIKey(" new-key\n")
        #expect(try await store.readAPIKey() == "new-key")
        #expect(await base.reads == 1)

        await store.invalidate()
        #expect(try await store.readAPIKey() == "new-key")
        #expect(await base.reads == 2)

        try await store.deleteAPIKey()
        #expect(await store.hasAPIKey() == false)
        await #expect(throws: LLMError.missingAPIKey) { try await store.readAPIKey() }
    }
}
