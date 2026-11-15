import Foundation
import os

/// 差分操作をノートに適用する純粋関数（DESIGN.md §4.4 の適用規則）。
public enum NotesReducer {
    /// 1回の応答で適用する操作の上限。超えた分は捨てる（モデルの暴走でノートが埋まるのを防ぐ）。
    public static let maxOpsPerResponse = 20

    /// 適用しなかった操作の理由。
    public enum IgnoreReason: Equatable, Sendable {
        /// タイトルが空（add_topic / rename_topic）
        case emptyTitle
        /// トピックのIDが既存のIDにも、この応答内の仮IDにも当たらない
        case unknownTopic
        /// 項目のIDが存在しない（update_item / remove_item）
        case unknownItem
        /// add_item に kind がない
        case missingKind
        /// add_item に text がない（空白だけも含む）
        case missingText
        /// 1回の応答の上限（20件）を超えた
        case overLimit
    }

    public struct IgnoredOp: Equatable, Sendable {
        /// 応答の中での位置（0始まり）
        public let index: Int
        public let op: NotesOp
        public let reason: IgnoreReason
    }

    public struct Result: Equatable, Sendable {
        public let notes: Notes
        /// 追加・変更されたトピックと項目のID（ハイライト用）。削除した項目は含まない
        public let changedIDs: Set<String>
        public let ignored: [IgnoredOp]
    }

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Notes")

    /// - Parameters:
    ///   - ops: 適用順に並んだ操作。仮ID（`new-1` など）はこの呼び出しの中だけで有効
    ///   - notes: 現在のノート
    public static func apply(_ ops: [NotesOp], to notes: Notes) -> Result {
        var notes = notes
        var changed = Set<String>()
        var ignored: [IgnoredOp] = []
        /// 仮ID → 実ID
        var temporaryTopicIDs: [String: String] = [:]

        func resolveTopic(_ id: String?) -> Int? {
            guard let id else { return nil }
            let realID = temporaryTopicIDs[id] ?? id
            return notes.topics.firstIndex { $0.id == realID }
        }

        func locateItem(_ id: String?) -> (topic: Int, item: Int)? {
            guard let id else { return nil }
            for (topicIndex, topic) in notes.topics.enumerated() {
                if let itemIndex = topic.items.firstIndex(where: { $0.id == id }) {
                    return (topicIndex, itemIndex)
                }
            }
            return nil
        }

        for (index, op) in ops.enumerated() {
            func ignore(_ reason: IgnoreReason) {
                ignored.append(IgnoredOp(index: index, op: op, reason: reason))
            }

            guard index < maxOpsPerResponse else {
                ignore(.overLimit)
                continue
            }

            switch op.op {
            case .addTopic:
                guard let title = nonEmpty(op.title) else {
                    ignore(.emptyTitle)
                    continue
                }
                let id = "t\(notes.nextTopicNumber)"
                notes.nextTopicNumber += 1
                notes.topics.append(Topic(id: id, title: title))
                // 同じ仮IDが2回出た場合は、後の add_topic を指すようにする（直前に作ったものを指すのが自然なため）。
                if let temporaryID = op.topicID {
                    temporaryTopicIDs[temporaryID] = id
                }
                changed.insert(id)

            case .renameTopic:
                guard let topicIndex = resolveTopic(op.topicID) else {
                    ignore(.unknownTopic)
                    continue
                }
                guard let title = nonEmpty(op.title) else {
                    ignore(.emptyTitle)
                    continue
                }
                notes.topics[topicIndex].title = title
                changed.insert(notes.topics[topicIndex].id)

            case .addItem:
                guard let topicIndex = resolveTopic(op.topicID) else {
                    ignore(.unknownTopic)
                    continue
                }
                guard let kind = op.kind else {
                    ignore(.missingKind)
                    continue
                }
                guard let text = nonEmpty(op.text) else {
                    ignore(.missingText)
                    continue
                }
                let id = "i\(notes.nextItemNumber)"
                notes.nextItemNumber += 1
                notes.topics[topicIndex].items.append(
                    NoteItem(id: id, kind: kind, text: text, owner: nonEmpty(op.owner), due: nonEmpty(op.due))
                )
                changed.insert(id)

            case .updateItem:
                guard let location = locateItem(op.itemID) else {
                    ignore(.unknownItem)
                    continue
                }
                // null（と空文字）のフィールドは変えない。
                let original = notes.topics[location.topic].items[location.item]
                var item = original
                if let kind = op.kind { item.kind = kind }
                if let text = nonEmpty(op.text) { item.text = text }
                if let owner = nonEmpty(op.owner) { item.owner = owner }
                if let due = nonEmpty(op.due) { item.due = due }
                notes.topics[location.topic].items[location.item] = item
                // 何も変わらなかった場合はハイライトしない。
                if item != original {
                    changed.insert(item.id)
                }

            case .removeItem:
                guard let location = locateItem(op.itemID) else {
                    ignore(.unknownItem)
                    continue
                }
                let removed = notes.topics[location.topic].items.remove(at: location.item)
                changed.remove(removed.id)
            }
        }

        for entry in ignored {
            // 本文（title / text）は会議の内容なのでログに出さない。種類と理由だけ残す。
            logger.notice("op を無視した: #\(entry.index) \(entry.op.op.rawValue, privacy: .public) \(String(describing: entry.reason), privacy: .public)")
        }
        return Result(notes: notes, changedIDs: changed, ignored: ignored)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
