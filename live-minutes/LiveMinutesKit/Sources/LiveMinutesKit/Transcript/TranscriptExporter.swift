import Foundation

/// 録音経過時間の表示（`HH:MM:SS`）。
public enum ElapsedTimeFormat {
    /// - Parameter seconds: 録音開始からの秒数。負や有限でない値は0として扱う
    public static func string(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(Int(seconds), 0) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

/// 文字起こしの書き出し（コピーとファイル保存）用の整形。画面と同じく、各行に開始時刻を付ける。
public enum TranscriptExporter {
    /// プレーンテキスト。1行目に会議名、2行目に開始日時、空行の後に `[HH:MM:SS] 本文` を並べる。
    public static func plainText(title: String, startedAt: Date?, segments: [TranscriptSegment]) -> String {
        var lines = [title]
        if let startedAt {
            lines.append(dateString(startedAt))
        }
        lines.append("")
        lines += segments.map { "[\(ElapsedTimeFormat.string($0.start))] \(singleLine($0.text))" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Markdown。見出しに会議名、開始日時、その後に `- **HH:MM:SS** 本文` を並べる。
    public static func markdown(title: String, startedAt: Date?, segments: [TranscriptSegment]) -> String {
        var lines = ["# \(singleLine(title))", ""]
        if let startedAt {
            lines.append("開始: \(dateString(startedAt))")
            lines.append("")
        }
        lines.append("## 文字起こし")
        lines.append("")
        lines += segments.map { "- **\(ElapsedTimeFormat.string($0.start))** \(escapeMarkdown(singleLine($0.text)))" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 書き出し時の既定のファイル名（拡張子なし）。ファイル名に使えない文字を置き換える。
    public static func suggestedFileName(title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let replaced = title.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
        // 先頭の「.」は隠しファイルになるので取り除き、長すぎる名前は切り詰める。
        let cleaned = String(replaced.trimmingCharacters(in: .whitespaces).drop { $0 == "." }.prefix(100))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "文字起こし" : cleaned
    }

    static func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// 改行を含むと1行1件の形が崩れるので、空白に置き換える。
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 行頭の記号や強調記号が Markdown として解釈されないようにする。
    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]#<>|".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
