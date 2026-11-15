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
    }

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
        self.notes = NotesPayload(topics: notes.topics.map { topic in
            TopicPayload(id: topic.id, title: topic.title, items: topic.items.map { item in
                ItemPayload(id: item.id, kind: item.kind, text: item.text, owner: item.owner, due: item.due)
            })
        })
        self.recentContext = recentContext
        newTranscript = segments.map { TranscriptLine(t: ElapsedTimeFormat.string($0.start), text: $0.text) }
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
