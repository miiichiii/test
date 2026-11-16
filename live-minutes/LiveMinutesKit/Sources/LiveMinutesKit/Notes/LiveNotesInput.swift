import Foundation

/// ライブ更新（Luna）へ送る入力（DESIGN.md §4.5 の JSON）。
///
/// ノートは採番用のカウンタを含めない形にし、`owner` と `due` は値がなくても null を明示する。
/// トップレベルのキーは設計書の順（meeting → notes → recent_context → new_transcript）に手でつなぐ。
/// 毎回変わる new_transcript を最後に置き、先頭一致で効くプロバイダのプロンプトキャッシュを効きやすくするため。
/// 各部分の中は `sortedKeys` で並びを固定し、同じ内容なら毎回同じ文字列にする。
struct LiveNotesInput: Encodable {
    struct Meeting: Encodable {
        let title: String
        let glossary: [String]
    }

    struct NotesPayload: Encodable {
        let topics: [TopicPayload]
    }

    struct TopicPayload: Encodable {
        let id: String
        let title: String
        let items: [ItemPayload]
        /// 長い会議で、このトピックの項目を省いて送った（Phase 6）。省いていなければキーを出さない
        var itemsOmitted = false

        enum CodingKeys: String, CodingKey {
            case id, title, items
            case itemsOmitted = "items_omitted"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(items, forKey: .items)
            if itemsOmitted { try container.encode(true, forKey: .itemsOmitted) }
        }
    }

    /// ノートの JSON がこれを超えたら、古いトピックの項目を省く（DESIGN.md §4.5。Phase 6）
    static let notesLimitCharacters = 6_000
    /// 省くときも、項目をすべて送る直近のトピックの数
    static let fullRecentTopics = 3

    struct ItemPayload: Encodable {
        let id: String
        let kind: NoteKind
        let text: String
        let owner: String?
        let due: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, text, owner, due
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encode(text, forKey: .text)
            // 既定の合成では nil のキーが省かれるので、null を明示する（スキーマの形とそろえる）。
            try container.encode(owner, forKey: .owner)
            try container.encode(due, forKey: .due)
        }
    }

    struct TranscriptLine: Encodable {
        /// 録音経過時間（HH:MM:SS）
        let t: String
        let text: String
    }

    let meeting: Meeting
    let notes: NotesPayload
    let recentContext: String
    let newTranscript: [TranscriptLine]

    enum CodingKeys: String, CodingKey {
        case meeting, notes
        case recentContext = "recent_context"
        case newTranscript = "new_transcript"
    }

    init(title: String, glossary: [String], notes: Notes, recentContext: String, segments: [TranscriptSegment]) {
        meeting = Meeting(title: title, glossary: glossary)
        self.notes = NotesPayload.trimmed(notes)
        self.recentContext = recentContext
        newTranscript = segments.map(TranscriptLine.init)
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func part<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        return """
        {"meeting":\(try part(meeting)),"notes":\(try part(notes)),\
        "recent_context":\(try part(recentContext)),"new_transcript":\(try part(newTranscript))}
        """
    }
}

extension LiveNotesInput.NotesPayload {
    /// 採番用のカウンタを含めない形にする（議事録の入力でも使う）
    init(_ notes: Notes) {
        topics = notes.topics.map { topic in
            LiveNotesInput.TopicPayload(id: topic.id, title: topic.title, items: topic.items.map { item in
                LiveNotesInput.ItemPayload(id: item.id, kind: item.kind, text: item.text, owner: item.owner, due: item.due)
            })
        }
    }
}

extension LiveNotesInput.TranscriptLine {
    init(_ segment: TranscriptSegment) {
        self.init(t: ElapsedTimeFormat.string(segment.start), text: segment.text)
    }
}

extension LiveNotesInput.NotesPayload {
    /// 長い会議のために絞った形（Phase 6）。JSON が上限を超えたら、直近の3トピックだけ項目を送り、
    /// それより前のトピックはタイトルだけにする（`items_omitted: true`）。省いたトピックへの `add_item` も適用できる
    /// （ノートの正はエンジンが持つ全体なので）。
    static func trimmed(
        _ notes: Notes,
        limit: Int = LiveNotesInput.notesLimitCharacters,
        recent: Int = LiveNotesInput.fullRecentTopics
    ) -> LiveNotesInput.NotesPayload {
        let full = LiveNotesInput.NotesPayload(notes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(full), data.count > limit, full.topics.count > recent else { return full }
        let cut = full.topics.count - recent
        var topics = full.topics
        for index in 0..<cut {
            topics[index] = LiveNotesInput.TopicPayload(id: topics[index].id, title: topics[index].title, items: [], itemsOmitted: true)
        }
        return LiveNotesInput.NotesPayload(topics: topics)
    }
}
