import Foundation
import os

/// セッションの保存（DESIGN.md §4.9）。
///
/// `<rootDirectory>/<セッションID>/` に `meta.json` と `transcript.jsonl` を置く。
/// 一覧・削除は Phase 5 で足す。
public actor SessionRepository {
    public enum RepositoryError: Error, Equatable, Sendable {
        /// 書き込み先のファイルを開けない
        case cannotOpenTranscript
    }

    public nonisolated let rootDirectory: URL
    /// 追記中の `transcript.jsonl`。セッション中は開いたままにする。
    private var transcriptHandles: [UUID: FileHandle] = [:]

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Persistence")
    static let metaFileName = "meta.json"
    static let transcriptFileName = "transcript.jsonl"

    /// 既定の保存先。サンドボックス下では
    /// `~/Library/Containers/<バンドルID>/Data/Library/Application Support/LiveMinutes/sessions/` になる。
    public static var defaultRootDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "LiveMinutes", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// - Parameter rootDirectory: セッションのフォルダを置く場所。テストでは必ず一時フォルダを渡す
    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public nonisolated func directory(for id: UUID) -> URL {
        rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - 作成と meta.json

    /// セッションのフォルダを作り、`meta.json` と空の `transcript.jsonl` を書く。
    public func createSession(_ meta: SessionMeta) throws {
        let directory = directory(for: meta.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try writeMeta(meta)
            let transcriptURL = directory.appending(path: Self.transcriptFileName)
            if !FileManager.default.fileExists(atPath: transcriptURL.path(percentEncoded: false)) {
                try Data().write(to: transcriptURL)
            }
        } catch {
            // 途中で失敗したら、中途半端なフォルダを残さない。
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func writeMeta(_ meta: SessionMeta) throws {
        let url = directory(for: meta.id).appending(path: Self.metaFileName)
        try Self.metaEncoder.encode(meta).write(to: url, options: .atomic)
    }

    public func loadMeta(id: UUID) throws -> SessionMeta {
        let url = directory(for: id).appending(path: Self.metaFileName)
        return try Self.metaDecoder.decode(SessionMeta.self, from: Data(contentsOf: url))
    }

    // MARK: - transcript.jsonl

    /// 確定セグメントを1行追記する。行と改行を1回の書き込みで書く。
    ///
    /// fsync はしない。書き込んだデータはカーネルに渡っているので、アプリが強制終了しても残る
    /// （失われるのは電源断などの場合だけ）。
    public func appendSegment(_ segment: TranscriptSegment, to id: UUID) throws {
        var line = try Self.lineEncoder.encode(segment)
        line.append(0x0A)
        let handle = try transcriptHandle(for: id)
        do {
            try handle.write(contentsOf: line)
        } catch {
            // 途中まで書けた切れ端が残っていると、次の行がその続きに書かれて2行とも読めなくなる。
            // ハンドルを閉じておけば、次の追記で開き直すときに末尾の改行を確かめて足す。
            transcriptHandles.removeValue(forKey: id)
            try? handle.close()
            throw error
        }
    }

    /// 追記用に開いているファイルを閉じる（セッションの終了時）。
    public func closeTranscript(for id: UUID) {
        guard let handle = transcriptHandles.removeValue(forKey: id) else { return }
        try? handle.close()
    }

    /// `transcript.jsonl` を読む。デコードできない行（異常終了で途中まで書かれた最後の行など）は飛ばす。
    public func loadTranscript(id: UUID) throws -> TranscriptLoadResult {
        let url = directory(for: id).appending(path: Self.transcriptFileName)
        let result = Self.decodeLines(try Data(contentsOf: url))
        if result.skippedLineCount > 0 {
            // 本文は会議の内容なのでログに出さない。件数だけ残す。
            Self.logger.notice("transcript.jsonl の読めない行を \(result.skippedLineCount) 行飛ばした")
        }
        return result
    }

    /// 1行ずつデコードする。ファイル全体を String にすると、最後の行がマルチバイト文字の途中で切れていたとき
    /// 全体の変換に失敗するので、バイト列のまま改行（0x0A）で分ける。
    static func decodeLines(_ data: Data) -> TranscriptLoadResult {
        var segments: [TranscriptSegment] = []
        var skipped = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let segment = try? lineDecoder.decode(TranscriptSegment.self, from: Data(line)) {
                segments.append(segment)
            } else {
                skipped += 1
            }
        }
        return TranscriptLoadResult(segments: segments, skippedLineCount: skipped)
    }

    private func transcriptHandle(for id: UUID) throws -> FileHandle {
        if let handle = transcriptHandles[id] {
            return handle
        }
        let url = directory(for: id).appending(path: Self.transcriptFileName)
        // FileHandle(forWritingTo:) はファイルがないと失敗し、追記モードでもないので、作ってから末尾へ移る。
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forUpdating: url)
        let end = try handle.seekToEnd()
        // 前回の最後の行が改行なしで切れていた場合、その続きに書かないよう改行を足す。
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if last != Data([0x0A]) {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        transcriptHandles[id] = handle
        return handle
    }

    // MARK: - エンコード

    private static var metaEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var metaDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 1行1件にするため、整形（改行）はしない。
    private static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var lineDecoder: JSONDecoder { JSONDecoder() }
}

/// `transcript.jsonl` の読み込み結果。
public struct TranscriptLoadResult: Equatable, Sendable {
    public let segments: [TranscriptSegment]
    /// デコードできずに飛ばした行の数
    public let skippedLineCount: Int
}
