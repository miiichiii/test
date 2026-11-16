import Foundation
import Observation
import os

/// 議事録の仕上げ（Sol）へ送る入力（DESIGN.md §4.6）。
///
/// トップレベルのキーは meeting → notes → transcript の順に手でつなぐ（各部分の中は `sortedKeys` で並びを固定する）。
struct MinutesInput {
    struct Meeting: Encodable {
        let title: String
        /// 開始日時（`yyyy-MM-dd HH:mm`、端末のタイムゾーン）
        let startedAt: String
        /// 所要時間（一時停止を除く録音時間。HH:MM:SS）
        let duration: String
        let glossary: [String]

        enum CodingKeys: String, CodingKey {
            case title, glossary, duration
            case startedAt = "started_at"
        }
    }

    let meeting: Meeting
    let notes: LiveNotesInput.NotesPayload
    let transcript: [LiveNotesInput.TranscriptLine]

    init(meta: SessionMeta, glossary: [String], notes: Notes, segments: [TranscriptSegment], timeZone: TimeZone = .current) {
        meeting = Meeting(
            title: meta.title,
            startedAt: Self.dateString(meta.startedAt, timeZone: timeZone),
            duration: ElapsedTimeFormat.string(meta.duration ?? (segments.last?.end ?? 0)),
            glossary: glossary
        )
        self.notes = LiveNotesInput.NotesPayload(notes)
        transcript = segments.map(LiveNotesInput.TranscriptLine.init)
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func part<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        return """
        {"meeting":\(try part(meeting)),"notes":\(try part(notes)),"transcript":\(try part(transcript))}
        """
    }
}

/// 議事録を作る相手。テストでは偽物に差し替える。
public protocol MinutesGenerating: Sendable {
    /// 今の接続方法で、議事録を作れるか（資格情報が設定されているか）
    func isConfigured() async -> Bool
    /// 入力の JSON を送り、議事録の Markdown の差分を順に返す
    func minutesStream(input: String) async -> AsyncThrowingStream<String, any Error>
}

/// Sol に議事録を頼む（テキストのストリーミング）。
public struct MinutesWriter: MinutesGenerating {
    private let client: any LLMClient
    private let systemPrompt: String
    private let modelSelection: @MainActor @Sendable () -> NotesEngine.ModelSelection
    private let configured: @MainActor @Sendable () async -> Bool

    /// - Parameters:
    ///   - modelSelection: 議事録の仕上げ用のモデルと推論量（送るたびに設定から読む）
    ///   - isConfigured: 資格情報が設定されているか
    public init(
        client: any LLMClient,
        systemPrompt: String,
        modelSelection: @escaping @MainActor @Sendable () -> NotesEngine.ModelSelection,
        isConfigured: @escaping @MainActor @Sendable () async -> Bool
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.modelSelection = modelSelection
        self.configured = isConfigured
    }

    public func isConfigured() async -> Bool {
        await configured()
    }

    public func minutesStream(input: String) async -> AsyncThrowingStream<String, any Error> {
        let selection = await modelSelection()
        return client.streamText(TextStreamRequest(
            model: selection.model,
            instructions: systemPrompt,
            input: input,
            reasoningEffort: selection.reasoningEffort
        ))
    }
}

/// 議事録の表示と生成（DESIGN.md §4.6）。届いた分から `text` に足していく。
///
/// - 完了したときだけ `minutes.md` に保存する。途中で失敗・中止したら保存せず、前に保存した内容に戻す
/// - 生成は1本だけ。新しく頼むと前のものを止める
@MainActor
@Observable
public final class MinutesStore {
    public enum State: Equatable, Sendable {
        /// 議事録がない（まだ作っていない）
        case idle
        case generating
        case completed
        /// 作れなかった（理由）。前に保存した議事録があれば `text` に戻してある
        case failed(String)
        /// 作らなかった（資格情報がない、文字起こしがない、など）
        case skipped(String)
    }

    public private(set) var state: State = .idle
    public private(set) var text = ""
    /// 表示しているセッション
    public private(set) var sessionID: UUID?

    @ObservationIgnored private let generator: (any MinutesGenerating)?
    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var currentTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Minutes")

    public init(generator: (any MinutesGenerating)?, repository: SessionRepository) {
        self.generator = generator
        self.repository = repository
    }

    public var isGenerating: Bool { state == .generating }

    /// 表示を空にする（新しい会議の開始時）。生成中なら止める
    public func reset() {
        cancel()
        // 止めた生成の結果が、後から表示を書き換えないようにする。
        generation += 1
        state = .idle
        text = ""
        sessionID = nil
    }

    /// 保存してある議事録を読む
    public func load(sessionID: UUID) async {
        cancel()
        generation += 1
        self.sessionID = sessionID
        let saved = (try? await repository.loadMinutes(id: sessionID)) ?? nil
        guard self.sessionID == sessionID else { return }
        text = saved ?? ""
        state = saved == nil ? .idle : .completed
    }

    /// 生成を止める（不完全な内容は保存しない）
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// 議事録を作る。終わる（完了・失敗・中止）まで待つ。
    public func generate(meta: SessionMeta, segments: [TranscriptSegment], notes: Notes, glossary: [String]) async {
        cancel()
        generation += 1
        let myGeneration = generation
        sessionID = meta.id
        let previous = (try? await repository.loadMinutes(id: meta.id)) ?? nil
        guard myGeneration == generation else { return }

        guard let generator else {
            finish(.skipped("議事録を作る設定がありません。"), restoring: previous)
            return
        }
        guard !segments.isEmpty else {
            finish(.skipped("文字起こしがないため、議事録は作りません。"), restoring: previous)
            return
        }
        guard await generator.isConfigured() else {
            finish(.skipped("OpenAI への接続（API キーか ChatGPT へのログイン）が設定されていないため、議事録は作りません。設定してから「作り直す」を押してください。"), restoring: previous)
            return
        }
        let input: String
        do {
            input = try MinutesInput(meta: meta, glossary: glossary, notes: notes, segments: segments).jsonString()
        } catch {
            finish(.failed("議事録の入力を作れませんでした。"), restoring: previous)
            return
        }

        state = .generating
        text = ""
        let repository = self.repository
        let task = Task { [weak self] in
            var collected = ""
            do {
                let stream = await generator.minutesStream(input: input)
                for try await delta in stream {
                    collected += delta
                    self?.append(delta, generation: myGeneration)
                }
                // 読む側がキャンセルされると、ストリームはエラーなしで終わる。途中までを完了として保存しない。
                try Task.checkCancellation()
                let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw LLMError.invalidOutput }
                try await repository.writeMinutes(trimmed, to: meta.id)
                self?.complete(trimmed, generation: myGeneration)
            } catch is CancellationError {
                self?.finish(.failed("議事録の作成を中止しました。"), restoring: previous, generation: myGeneration)
            } catch {
                Self.logger.error("議事録を作れない: \((error as? LLMError)?.logSummary ?? String(describing: type(of: error)), privacy: .public)")
                let message = (error as? LocalizedError)?.errorDescription ?? "議事録を作れませんでした。"
                self?.finish(.failed(message), restoring: previous, generation: myGeneration)
            }
        }
        currentTask = task
        await task.value
        if currentTask == task { currentTask = nil }
    }

    private func append(_ delta: String, generation: Int) {
        guard generation == self.generation, state == .generating else { return }
        text += delta
    }

    private func complete(_ minutes: String, generation: Int) {
        guard generation == self.generation else { return }
        text = minutes
        state = .completed
    }

    private func finish(_ newState: State, restoring previous: String?, generation: Int? = nil) {
        if let generation, generation != self.generation { return }
        text = previous ?? ""
        state = newState
    }
}
