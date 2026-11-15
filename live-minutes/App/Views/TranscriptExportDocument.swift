import SwiftUI
import UniformTypeIdentifiers

/// 文字起こしの書き出し形式。
nonisolated enum TranscriptExportFormat {
    case plainText
    case markdown

    var contentType: UTType {
        switch self {
        case .plainText: .plainText
        // Markdown の型が登録されていない環境でも保存できるよう、拡張子から作り、なければテキストにする。
        case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        }
    }
}

/// `fileExporter` に渡す書き出し用の文書（UTF-8 のテキスト）。
nonisolated struct TranscriptExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    static var writableContentTypes: [UTType] {
        [TranscriptExportFormat.plainText.contentType, TranscriptExportFormat.markdown.contentType]
    }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
