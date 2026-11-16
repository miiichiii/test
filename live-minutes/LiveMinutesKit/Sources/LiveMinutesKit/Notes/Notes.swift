import Foundation

/// 項目の種類。
public enum NoteKind: String, Codable, CaseIterable, Sendable {
    /// 要点
    case point
    /// 決定事項
    case decision
    /// ToDo
    case action
    /// 未解決の質問
    case question

    /// 画面に出すラベル（色だけに頼らず、文字でも種類が分かるようにする）
    public var label: String {
        switch self {
        case .point: "要点"
        case .decision: "決定"
        case .action: "ToDo"
        case .question: "質問"
        }
    }
}

/// ノートの1項目。
public struct NoteItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: NoteKind
    public var text: String
    public var owner: String?
    public var due: String?
    /// 参加者が手で直した（Phase 6）。以後のモデルの `update_item` と `remove_item` を無視する
    public var isPinned: Bool

    public init(id: String, kind: NoteKind, text: String, owner: String? = nil, due: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.owner = owner
        self.due = due
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, owner, due
        case isPinned = "is_pinned"
    }

    /// Phase 5 までの notes.json（`is_pinned` がない）も読めるようにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(NoteKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

/// トピック。項目を順に並べる。
public struct Topic: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var items: [NoteItem]

    public init(id: String, title: String, items: [NoteItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// ノート全体（DESIGN.md §4.4）。
///
/// ID はアプリが採番する（トピックは `t1`, `t2` …、項目は `i1`, `i2` …）。
/// 削除した項目の番号を再利用しないよう、次の番号を持つ（モデルが古いIDで別の項目を指さないため）。
public struct Notes: Codable, Equatable, Sendable {
    public var topics: [Topic]
    public var nextTopicNumber: Int
    public var nextItemNumber: Int

    public init(topics: [Topic] = [], nextTopicNumber: Int = 1, nextItemNumber: Int = 1) {
        self.topics = topics
        self.nextTopicNumber = nextTopicNumber
        self.nextItemNumber = nextItemNumber
    }

    public var isEmpty: Bool { topics.isEmpty }
}
