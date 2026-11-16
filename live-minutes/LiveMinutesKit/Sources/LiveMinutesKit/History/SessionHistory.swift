import Foundation
import Observation
import os

/// 過去のセッションの一覧と、選んだセッションの中身（Phase 5。DESIGN.md §4.9・§5）。
@MainActor
@Observable
public final class SessionHistory {
    /// 開いたセッションの中身（読むだけ。議事録は `minutes` が持つ）
    public struct Detail: Equatable, Sendable {
        public let meta: SessionMeta
        public let segments: [TranscriptSegment]
        public let notes: Notes
        /// 読めなかった文字起こしの行の数
        public let skippedLineCount: Int
    }

    public private(set) var sessions: [SessionMeta] = []
    public private(set) var detail: Detail?
    /// 開いたセッションの議事録（表示と作り直し）
    public let minutes: MinutesStore

    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private let glossary: @MainActor () -> [String]
    @ObservationIgnored private var openGeneration = 0

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "History")

    public init(
        repository: SessionRepository,
        minutesGenerator: (any MinutesGenerating)?,
        glossary: @escaping @MainActor () -> [String] = { [] }
    ) {
        self.repository = repository
        self.glossary = glossary
        minutes = MinutesStore(generator: minutesGenerator, repository: repository)
    }

    /// 一覧を読み直す（新しい順。壊れたフォルダは飛ばす）
    public func refresh() async {
        sessions = await repository.listSessions()
    }

    /// セッションを開く。読めない場合は閉じた状態にする
    public func open(_ id: UUID) async {
        openGeneration += 1
        let myGeneration = openGeneration
        do {
            let meta = try await repository.loadMeta(id: id)
            let transcript = (try? await repository.loadTranscript(id: id)) ?? TranscriptLoadResult(segments: [], skippedLineCount: 0)
            let notes = (try? await repository.loadNotes(id: id)) ?? Notes()
            guard myGeneration == openGeneration else { return }
            detail = Detail(meta: meta, segments: transcript.segments, notes: notes, skippedLineCount: transcript.skippedLineCount)
            await minutes.load(sessionID: id)
        } catch {
            guard myGeneration == openGeneration else { return }
            Self.logger.error("セッションを開けない: \(String(describing: type(of: error)), privacy: .public)")
            detail = nil
            minutes.reset()
        }
    }

    /// 開いているセッションを閉じる
    public func close() {
        openGeneration += 1
        detail = nil
        minutes.reset()
    }

    /// 開いているセッションの議事録を作り直す
    public func regenerateMinutes() async {
        guard let detail else { return }
        await minutes.generate(meta: detail.meta, segments: detail.segments, notes: detail.notes, glossary: glossary())
    }

    /// セッションを消す（保存フォルダごと）。開いていれば閉じる
    public func delete(_ id: UUID) async throws {
        if detail?.meta.id == id { close() }
        try await repository.deleteSession(id: id)
        await refresh()
    }
}
