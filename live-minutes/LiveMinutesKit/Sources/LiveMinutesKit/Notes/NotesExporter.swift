import Foundation

/// ノートの書き出し（Markdown のコピー）用の整形。
public enum NotesExporter {
    /// トピックを見出しに、項目を箇条書きにする。種類はラベルの文字で示し、ToDo には担当と期限を添える。
    public static func markdown(title: String, notes: Notes) -> String {
        var lines = ["# \(singleLine(title))", ""]
        if notes.topics.isEmpty {
            lines.append("（ノートはまだありません）")
        }
        for topic in notes.topics {
            lines.append("## \(singleLine(topic.title))")
            lines.append("")
            for item in topic.items {
                lines.append("- [\(item.kind.label)] \(singleLine(item.text))\(suffix(for: item))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// ToDo の担当と期限（例: 「（担当: 佐藤、期限: 金曜）」）。どちらもなければ空。
    public static func suffix(for item: NoteItem) -> String {
        var parts: [String] = []
        if let owner = item.owner, !owner.isEmpty { parts.append("担当: \(singleLine(owner))") }
        if let due = item.due, !due.isEmpty { parts.append("期限: \(singleLine(due))") }
        return parts.isEmpty ? "" : "（\(parts.joined(separator: "、"))）"
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
