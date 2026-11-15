import Foundation
import Testing
@testable import LiveMinutesKit

@Suite("NotesReducer")
struct NotesReducerTests {
    /// t1「リリース日程」に i1（要点）がある状態。
    private var base: Notes {
        Notes(
            topics: [Topic(id: "t1", title: "リリース日程", items: [NoteItem(id: "i1", kind: .point, text: "テストが2日遅れている")])],
            nextTopicNumber: 2,
            nextItemNumber: 2
        )
    }

    // MARK: - 正常系

    @Test("add_topic は末尾にトピックを追加し、仮IDを同じ応答内の add_item で使える")
    func addTopicAndResolveTemporaryID() {
        let result = NotesReducer.apply([
            NotesOp(op: .addTopic, topicID: "new-1", title: "告知"),
            NotesOp(op: .addItem, topicID: "new-1", kind: .action, text: "告知文を修正する", owner: "佐藤", due: "金曜"),
            NotesOp(op: .renameTopic, topicID: "new-1", title: "告知文"),
        ], to: base)

        #expect(result.ignored.isEmpty)
        #expect(result.notes.topics.map(\.id) == ["t1", "t2"])
        #expect(result.notes.topics[1].title == "告知文")
        #expect(result.notes.topics[1].items == [NoteItem(id: "i2", kind: .action, text: "告知文を修正する", owner: "佐藤", due: "金曜")])
        #expect(result.notes.nextTopicNumber == 3)
        #expect(result.notes.nextItemNumber == 3)
        #expect(result.changedIDs == ["t2", "i2"])
    }

    @Test("仮IDは1回の適用の中だけで有効")
    func temporaryIDDoesNotCarryOver() {
        let first = NotesReducer.apply([NotesOp(op: .addTopic, topicID: "new-1", title: "告知")], to: base)
        let second = NotesReducer.apply([NotesOp(op: .addItem, topicID: "new-1", kind: .point, text: "x")], to: first.notes)

        #expect(second.ignored.map(\.reason) == [.unknownTopic])
        #expect(second.notes == first.notes)
    }

    @Test("rename_topic はタイトルを変える")
    func renameTopic() {
        let result = NotesReducer.apply([NotesOp(op: .renameTopic, topicID: "t1", title: "リリース計画")], to: base)
        #expect(result.notes.topics[0].title == "リリース計画")
        #expect(result.changedIDs == ["t1"])
    }

    @Test("add_item は既存トピックの末尾に追加し、前後の空白を除く")
    func addItemToExistingTopic() {
        let result = NotesReducer.apply([NotesOp(op: .addItem, topicID: "t1", kind: .decision, text: "  来週水曜に延期  ")], to: base)
        #expect(result.notes.topics[0].items.map(\.id) == ["i1", "i2"])
        #expect(result.notes.topics[0].items[1].text == "来週水曜に延期")
        #expect(result.notes.topics[0].items[1].owner == nil)
    }

    @Test("update_item は null でないフィールドだけ上書きする")
    func updateItemOverwritesNonNullFields() {
        var notes = base
        notes.topics[0].items[0].owner = "鈴木"
        let result = NotesReducer.apply([NotesOp(op: .updateItem, itemID: "i1", kind: .action, text: nil, owner: nil, due: "明日")], to: notes)

        let item = result.notes.topics[0].items[0]
        #expect(item.kind == .action)
        #expect(item.text == "テストが2日遅れている")
        #expect(item.owner == "鈴木")
        #expect(item.due == "明日")
        #expect(result.changedIDs == ["i1"])
    }

    @Test("全フィールドが null の update_item は何も変えず、ハイライトもしない")
    func noOpUpdate() {
        let result = NotesReducer.apply([NotesOp(op: .updateItem, itemID: "i1")], to: base)
        #expect(result.notes == base)
        #expect(result.changedIDs.isEmpty)
        #expect(result.ignored.isEmpty)
    }

    @Test("仮IDが既存のIDと同じ形なら、同じ応答内の add_topic を優先する")
    func temporaryIDShadowsExistingID() {
        let result = NotesReducer.apply([
            NotesOp(op: .addTopic, topicID: "t1", title: "新しい議題"),
            NotesOp(op: .addItem, topicID: "t1", kind: .point, text: "新しい議題の要点"),
        ], to: base)
        #expect(result.notes.topics[0].items.count == 1)
        #expect(result.notes.topics[1].items.map(\.text) == ["新しい議題の要点"])
    }

    @Test("remove_item は項目を消し、番号は再利用しない")
    func removeItem() {
        let removed = NotesReducer.apply([NotesOp(op: .removeItem, itemID: "i1")], to: base)
        #expect(removed.notes.topics[0].items.isEmpty)
        #expect(removed.changedIDs.isEmpty)

        let added = NotesReducer.apply([NotesOp(op: .addItem, topicID: "t1", kind: .point, text: "新しい項目")], to: removed.notes)
        #expect(added.notes.topics[0].items.map(\.id) == ["i2"])
    }

    @Test("同じ応答内で追加して消した項目は、変更されたIDに含めない")
    func addThenRemoveInSameResponse() {
        let result = NotesReducer.apply([
            NotesOp(op: .addItem, topicID: "t1", kind: .point, text: "一時的"),
            NotesOp(op: .removeItem, itemID: "i2"),
        ], to: base)
        #expect(result.notes == Notes(topics: base.topics, nextTopicNumber: 2, nextItemNumber: 3))
        #expect(result.changedIDs.isEmpty)
    }

    @Test("空の ops では何も変わらない")
    func emptyOps() {
        let result = NotesReducer.apply([], to: base)
        #expect(result.notes == base)
        #expect(result.changedIDs.isEmpty)
        #expect(result.ignored.isEmpty)
    }

    // MARK: - 無視する条件

    @Test("無視する条件（DESIGN.md §4.4 の表）", arguments: [
        (NotesOp(op: .addTopic, topicID: "new-1", title: " "), NotesReducer.IgnoreReason.emptyTitle),
        (NotesOp(op: .addTopic, topicID: "new-1", title: nil), .emptyTitle),
        (NotesOp(op: .renameTopic, topicID: "t9", title: "x"), .unknownTopic),
        (NotesOp(op: .renameTopic, topicID: nil, title: "x"), .unknownTopic),
        (NotesOp(op: .renameTopic, topicID: "t1", title: ""), .emptyTitle),
        (NotesOp(op: .addItem, topicID: "t9", kind: .point, text: "x"), .unknownTopic),
        (NotesOp(op: .addItem, topicID: "new-1", kind: .point, text: "x"), .unknownTopic),
        (NotesOp(op: .addItem, topicID: "t1", kind: nil, text: "x"), .missingKind),
        (NotesOp(op: .addItem, topicID: "t1", kind: .point, text: nil), .missingText),
        (NotesOp(op: .addItem, topicID: "t1", kind: .point, text: "  \n"), .missingText),
        (NotesOp(op: .updateItem, itemID: "i9", text: "x"), .unknownItem),
        (NotesOp(op: .updateItem, itemID: nil, text: "x"), .unknownItem),
        (NotesOp(op: .removeItem, itemID: "i9"), .unknownItem),
    ])
    func ignoredOps(op: NotesOp, reason: NotesReducer.IgnoreReason) {
        let result = NotesReducer.apply([op], to: base)
        #expect(result.notes == base)
        #expect(result.ignored == [NotesReducer.IgnoredOp(index: 0, op: op, reason: reason)])
    }

    @Test("無視した op があっても、残りは適用する")
    func continuesAfterIgnoredOp() {
        let result = NotesReducer.apply([
            NotesOp(op: .removeItem, itemID: "i9"),
            NotesOp(op: .addItem, topicID: "t1", kind: .question, text: "誰が担当？"),
        ], to: base)
        #expect(result.ignored.map(\.index) == [0])
        #expect(result.notes.topics[0].items.count == 2)
    }

    @Test("21件目以降は上限超過として捨てる")
    func overLimit() {
        let ops = (1...25).map { NotesOp(op: .addItem, topicID: "t1", kind: .point, text: "項目\($0)") }
        let result = NotesReducer.apply(ops, to: base)

        #expect(result.notes.topics[0].items.count == 1 + 20)
        #expect(result.notes.topics[0].items.last?.text == "項目20")
        #expect(result.ignored.map(\.index) == Array(20...24))
        #expect(result.ignored.allSatisfy { $0.reason == .overLimit })
    }
}

@Suite("NotesOp のデコード")
struct NotesOpDecodingTests {
    @Test("DESIGN.md §4.5 の出力例がそのままデコードできる")
    func decodesDesignExample() throws {
        let json = """
        {
          "ops": [
            { "op": "add_item", "topic_id": "t1", "item_id": null, "title": null, "kind": "decision", "text": "リリースを来週水曜に延期", "owner": null, "due": null },
            { "op": "add_item", "topic_id": "t1", "item_id": null, "title": null, "kind": "action", "text": "告知文を修正する", "owner": "佐藤", "due": "金曜" }
          ]
        }
        """
        let response = try NotesOpsResponse.decode(from: Data(json.utf8))
        #expect(response.ops == [
            NotesOp(op: .addItem, topicID: "t1", kind: .decision, text: "リリースを来週水曜に延期"),
            NotesOp(op: .addItem, topicID: "t1", kind: .action, text: "告知文を修正する", owner: "佐藤", due: "金曜"),
        ])
    }

    @Test("空の ops をデコードできる")
    func decodesEmpty() throws {
        #expect(try NotesOpsResponse.decode(from: Data(#"{"ops":[]}"#.utf8)).ops.isEmpty)
    }

    @Test("知らない op はデコードエラーになる")
    func rejectsUnknownOp() {
        let json = #"{"ops":[{"op":"delete_all","topic_id":null,"item_id":null,"title":null,"kind":null,"text":null,"owner":null,"due":null}]}"#
        #expect(throws: DecodingError.self) { try NotesOpsResponse.decode(from: Data(json.utf8)) }
    }
}

@MainActor
@Suite("NotesStore")
struct NotesStoreTests {
    @Test("適用すると、ノートと直近に変更されたIDが変わる")
    func applyUpdatesNotesAndHighlights() {
        let store = NotesStore()
        let ignored = store.apply([
            NotesOp(op: .addTopic, topicID: "new-1", title: "議題"),
            NotesOp(op: .addItem, topicID: "new-1", kind: .point, text: "要点"),
            NotesOp(op: .removeItem, itemID: "i9"),
        ])
        #expect(store.notes.topics.count == 1)
        #expect(store.recentlyChangedIDs == ["t1", "i1"])
        #expect(ignored.count == 1)

        store.clearHighlights()
        #expect(store.recentlyChangedIDs.isEmpty)
        store.reset()
        #expect(store.notes.isEmpty)
    }
}
