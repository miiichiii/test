import Foundation

/// ノートへの差分操作1件（`notes-ops.schema.json` の `ops` の1要素）。
///
/// スキーマでは全フィールドが必須で、使わないフィールドは null が入る。
public struct NotesOp: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case addTopic = "add_topic"
        case renameTopic = "rename_topic"
        case addItem = "add_item"
        case updateItem = "update_item"
        case removeItem = "remove_item"
    }

    public var op: Operation
    public var topicID: String?
    public var itemID: String?
    public var title: String?
    public var kind: NoteKind?
    public var text: String?
    public var owner: String?
    public var due: String?

    public init(
        op: Operation,
        topicID: String? = nil,
        itemID: String? = nil,
        title: String? = nil,
        kind: NoteKind? = nil,
        text: String? = nil,
        owner: String? = nil,
        due: String? = nil
    ) {
        self.op = op
        self.topicID = topicID
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.text = text
        self.owner = owner
        self.due = due
    }

    enum CodingKeys: String, CodingKey {
        case op
        case topicID = "topic_id"
        case itemID = "item_id"
        case title, kind, text, owner, due
    }
}

/// ライブ更新モデルの応答全体（`{"ops": [...]}`）。
public struct NotesOpsResponse: Codable, Equatable, Sendable {
    public var ops: [NotesOp]

    public init(ops: [NotesOp]) {
        self.ops = ops
    }

    public static func decode(from data: Data) throws -> NotesOpsResponse {
        try JSONDecoder().decode(NotesOpsResponse.self, from: data)
    }
}
