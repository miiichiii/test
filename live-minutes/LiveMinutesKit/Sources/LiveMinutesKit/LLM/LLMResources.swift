import Foundation

/// パッケージに同梱したプロンプトとスキーマ（`Sources/LiveMinutesKit/Resources/`）を読む。
public enum LLMResources {
    public enum ResourceError: Error, Equatable, Sendable {
        case notFound(String)
        case unreadable(String)
    }

    /// ライブ更新（Luna）のシステムプロンプト
    public static func liveNotesSystemPrompt() throws -> String {
        try text(named: "live-notes.system", extension: "md")
    }

    /// 議事録仕上げ（Sol）のシステムプロンプト
    public static func finalMinutesSystemPrompt() throws -> String {
        try text(named: "final-minutes.system", extension: "md")
    }

    /// ライブ更新の出力スキーマ（JSON Schema の生のバイト列）
    public static func notesOpsSchema() throws -> Data {
        try data(named: "notes-ops.schema", extension: "json")
    }

    static func data(named name: String, extension ext: String) throws -> Data {
        // Package.swift で Resources フォルダごとコピーしているので、バンドル内でも Resources/ の下にある。
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            throw ResourceError.notFound("\(name).\(ext)")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ResourceError.unreadable("\(name).\(ext)")
        }
    }

    static func text(named name: String, extension ext: String) throws -> String {
        guard let text = String(data: try data(named: name, extension: ext), encoding: .utf8) else {
            throw ResourceError.unreadable("\(name).\(ext)")
        }
        return text
    }
}

extension LLMResources.ResourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "アプリに同梱したファイル（\(name)）が見つかりません。アプリを入れ直してください。"
        case .unreadable(let name): "アプリに同梱したファイル（\(name)）を読めません。アプリを入れ直してください。"
        }
    }
}
