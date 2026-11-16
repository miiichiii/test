import Foundation
import os
import WhisperKit

/// WhisperKit（Argmax OSS 1.1.1）を使う `WhisperTranscriber`。
///
/// WhisperKit の型は Sendable でないので、この actor の中に閉じ込め、外へは文字列だけを返す。
actor WhisperKitTranscriber: WhisperTranscriber {
    private let pipe: WhisperKit

    private init(pipe: WhisperKit) {
        self.pipe = pipe
    }

    /// ダウンロード済みのモデルのフォルダから読み込む（ダウンロードはしない）。初回は Core ML のコンパイルで時間がかかる。
    static func load(modelFolder: URL) async throws -> WhisperKitTranscriber {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path(percentEncoded: false),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        return WhisperKitTranscriber(pipe: try await WhisperKit(config))
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined()
    }
}

/// Whisper のモデルのダウンロードと保存（DESIGN.md §4.2）。保存先はアプリのコンテナの `Application Support/LiveMinutes/models/`。
///
/// 送るのはモデルの取得の要求だけで、音声は送らない。どのモデルをどのフォルダに置いたかは `index.json` に書く。
public actor WhisperModelStore {
    /// 選べるモデル（名前は Hugging Face の `argmaxinc/whisperkit-coreml` のフォルダ名の後半）
    public struct Variant: Hashable, Sendable, Identifiable {
        public let id: String
        public let label: String
    }

    public static let variants: [Variant] = [
        Variant(id: "large-v3-v20240930_626MB", label: "高精度（large-v3）"),
        Variant(id: "large-v3-v20240930_turbo", label: "高精度・速い（large-v3 turbo）"),
        Variant(id: "small", label: "軽い（small）"),
        Variant(id: "base", label: "とても軽い（base）"),
    ]
    public static let defaultVariant = "large-v3-v20240930_626MB"

    private let baseURL: URL
    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Whisper")

    public static var defaultBaseURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "LiveMinutes", directoryHint: .isDirectory)
            .appending(path: "models", directoryHint: .isDirectory)
    }

    /// - Parameter baseURL: テストでは一時フォルダを渡す
    public init(baseURL: URL = WhisperModelStore.defaultBaseURL) {
        self.baseURL = baseURL
    }

    /// ダウンロード済みのモデルのフォルダ。なければ nil
    public func folder(for variant: String) -> URL? {
        guard let path = readIndex()[variant] else { return nil }
        let url = URL(filePath: path, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public func isDownloaded(_ variant: String) -> Bool {
        folder(for: variant) != nil
    }

    /// モデルをダウンロードする。キャンセルされたら途中で止める。
    public func download(_ variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: baseURL,
            progressCallback: { value in progress(value.fractionCompleted) }
        )
        try Task.checkCancellation()
        var index = readIndex()
        index[variant] = folder.path(percentEncoded: false)
        try writeIndex(index)
        Self.logger.info("Whisper のモデルをダウンロードした: \(variant, privacy: .public)")
    }

    /// モデルを消す。
    public func delete(_ variant: String) throws {
        var index = readIndex()
        if let path = index[variant] {
            try? FileManager.default.removeItem(at: URL(filePath: path, directoryHint: .isDirectory))
        }
        index[variant] = nil
        try writeIndex(index)
    }

    /// モデルを読み込む（`WhisperLocalEngine` の Loader に使う）。
    public func loadTranscriber(_ variant: String) async throws -> any WhisperTranscriber {
        guard let folder = folder(for: variant) else { throw TranscriptionError.whisperModelMissing }
        do {
            return try await WhisperKitTranscriber.load(modelFolder: folder)
        } catch {
            Self.logger.error("Whisper のモデルを読み込めない: \(String(describing: type(of: error)), privacy: .public)")
            throw TranscriptionError.whisperFailed(String(describing: type(of: error)))
        }
    }

    private var indexURL: URL { baseURL.appending(path: "index.json") }

    private func readIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return index
    }

    private func writeIndex(_ index: [String: String]) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }
}
