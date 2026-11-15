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

    /// op 単位で寛容に読む。読めない op だけを捨て、その数を返す（1件の不正で応答全体を捨てないため）。
    /// `ops` 自体がない、または JSON として読めない場合は投げる。
    public static func decodeLossy(from data: Data) throws -> (ops: [NotesOp], skippedCount: Int) {
        let lossy = try JSONDecoder().decode(LossyOps.self, from: data)
        let ops = lossy.ops.compactMap(\.value)
        return (ops, lossy.ops.count - ops.count)
    }

    private struct LossyOps: Decodable {
        let ops: [Lossy<NotesOp>]
    }
}

/// 読めなければ nil になる包み。`UnkeyedDecodingContainer` で直接 `try?` すると失敗時に位置が進まないので、この型で包む。
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
