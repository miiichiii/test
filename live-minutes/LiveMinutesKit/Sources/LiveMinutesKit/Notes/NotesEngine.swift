import Foundation
import os

/// ノートのライブ更新の状態（画面に出す）。
public enum LiveNotesStatus: Equatable, Sendable {
    /// 会議をしていない
    case inactive
    /// API キーがないので動かしていない
    case notConfigured
    /// 次の送信を待っている
    case waiting
    /// 送信して応答を待っている
    case updating
    /// 「要約の送信を一時停止」がオン
    case paused
    /// ネットワークにつながっていない（文字起こしは続く。つながったら送り直す。Phase 6）
    case offline
    /// 失敗した。`needsRetry` が true なら自動では送り直さない（「再試行」か資格情報の変更で再開する）。
    /// `action` は案内に出す次の操作
    case failed(message: String, needsRetry: Bool, action: NotesFailureAction = .checkSettings)
}

/// 失敗の案内に出す次の操作（DESIGN.md §4.11・§5）。
public enum NotesFailureAction: Equatable, Sendable {
    /// 設定を確かめる（API キー、モデルIDなど）
    case checkSettings
    /// ChatGPT の使用量を確かめる（使用量の上限）
    case manageUsage
    /// 設定画面で ChatGPT にログインし直す
    case signIn

    init(_ error: (any Error)?) {
        switch error as? LLMError {
        case .usageLimitReached?:
            self = .manageUsage
        case .chatGPTSignInRequired?, .chatGPTUnauthorized?, .chatGPTPlanNotGranted?, .chatGPTCredentialUnavailable?:
            self = .signIn
        default:
            self = .checkSettings
        }
    }
}

/// 確定セグメントをためて LLM（Luna）に送り、返ってきた差分をノートに適用する（DESIGN.md §4.5）。
///
/// セッションごとに新しく作る。ノートの正はこの actor が持つ `notes` で、適用した結果を `report` で画面へ渡す。
///
/// 送信の条件:
/// - 未送信の確定テキストが `minCharacters` 字以上、または未送信があり前回の完了から `maxInterval` 秒
/// - ただし前回の完了から `minInterval` 秒以内は送らない。同時に送るのは1本だけ
/// - 失敗したら、`maxInterval` 秒たつまで送り直さない
public actor NotesEngine {
    /// 会議中は変えない設定。セッションの開始時に作る。
    public struct Configuration: Sendable {
        public var meetingTitle: String
        public var glossary: [String]
        public var minCharacters: Int
        public var maxInterval: TimeInterval
        public var minInterval: TimeInterval
        public var requestTimeout: Duration
        /// `recent_context` の上限（文字数）
        public var recentContextLimit: Int
        /// 1回に送る未送信テキストの上限（文字数）。1回の応答で適用する op は20件までなので、送りすぎない
        public var maxBatchCharacters: Int
        /// 入力の内容で決まる失敗（拒否・出力不正など）が続いたら、そのバッチを捨てる回数
        public var maxContentFailures: Int

        public init(
            meetingTitle: String,
            glossary: [String],
            minCharacters: Int = AppSettings.defaultNotesMinCharacters,
            maxInterval: TimeInterval = AppSettings.defaultNotesMaxInterval,
            minInterval: TimeInterval = AppSettings.defaultNotesMinInterval,
            requestTimeout: Duration = .seconds(30),
            recentContextLimit: Int = 400,
            maxBatchCharacters: Int = 2000,
            maxContentFailures: Int = 2
        ) {
            // 設定に0や負の値が入っていても、間隔なしで送り続けないように丸める。
            self.meetingTitle = meetingTitle
            self.glossary = glossary
            self.minCharacters = max(minCharacters, 1)
            self.minInterval = max(minInterval, 1)
            self.maxInterval = max(maxInterval, self.minInterval)
            self.requestTimeout = requestTimeout
            self.recentContextLimit = max(recentContextLimit, 0)
            self.maxBatchCharacters = max(maxBatchCharacters, 1)
            self.maxContentFailures = max(maxContentFailures, 1)
        }
    }

    /// 送信のたびに読む設定（会議中に設定画面で直したら、次の送信から効く）。
    public struct ModelSelection: Sendable {
        public var model: String
        public var reasoningEffort: String?

        public init(model: String, reasoningEffort: String?) {
            self.model = model
            self.reasoningEffort = reasoningEffort
        }
    }

    /// 画面へ知らせること。
    public enum Event: Sendable {
        case applied(NotesReducer.Result)
        case status(LiveNotesStatus)
        /// 失敗が続いたため、ノートに反映せずに捨てたセグメントの数
        case dropped(Int)
    }

    public enum FinishMode: Sendable {
        /// 残りを条件に関係なく送り、終わるのを待つ（上限つき）
        case flush(timeout: TimeInterval)
        /// 送らずに終える（飛行中はキャンセルする）
        case abandon
    }

    private let client: any LLMClient
    private let configuration: Configuration
    private let clock: any NotesClock
    private let systemPrompt: String
    private let schema: Data
    private let modelSelection: @MainActor @Sendable () -> ModelSelection
    private let persist: @Sendable (Notes) async -> Void
    private let report: @MainActor @Sendable (Event) -> Void

    private(set) var notes = Notes()
    /// 未送信のセグメント（追記だけ）
    private(set) var pending: [TranscriptSegment] = []
    /// 送信に成功したセグメントの本文（recent_context 用。新しいものが後ろ）
    private var sentTexts: [String] = []
    private var lastCompletedAt: TimeInterval
    /// 失敗後、この時刻までは送らない
    private var retryNotBefore: TimeInterval?
    /// 直らない失敗で止まっている（自動では送らない）
    private(set) var isHalted = false
    /// 止まった理由（画面に出す。止まっている間は一時停止をオン・オフしても、この表示に戻す）
    private var haltMessage: String?
    /// 止まったときの案内の操作
    private var haltAction: NotesFailureAction = .checkSettings
    /// `retryNow` のたびに進める。送信中に資格情報が変わった（接続方法の切り替えなど）ことを見分けるため
    private var retryGeneration = 0
    private var contentFailures = 0
    private(set) var isPaused = false
    private var isFinishing = false
    /// 終了した。以後は適用も報告もしない
    private var isClosed = false
    private var inFlight: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var wakeGeneration = 0
    /// 次に条件を見直す予定の時刻（テスト用）
    private(set) var scheduledWakeAt: TimeInterval?

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Notes")
    static let schemaName = "notes_ops"

    public init(
        client: any LLMClient,
        configuration: Configuration,
        clock: any NotesClock,
        systemPrompt: String,
        schema: Data,
        modelSelection: @escaping @MainActor @Sendable () -> ModelSelection,
        persist: @escaping @Sendable (Notes) async -> Void,
        report: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        self.client = client
        self.configuration = configuration
        self.clock = clock
        self.systemPrompt = systemPrompt
        self.schema = schema
        self.modelSelection = modelSelection
        self.persist = persist
        self.report = report
        lastCompletedAt = clock.now()
    }

    var isInFlight: Bool { inFlight != nil }

    // MARK: - 受け付け

    /// 確定セグメントを受け取る。
    public func add(_ segment: TranscriptSegment) {
        guard !isFinishing, !isPaused else { return }
        pending.append(segment)
        evaluate()
    }

    /// 「要約の送信を一時停止」。オンにした時点の未送信分は捨てる（機微な話の冒頭が含まれうるため）。
    /// 飛行中のリクエストは最後まで待って結果を適用する（すでに送ってあり、取り消しても秘匿にならないため）。
    public func setPaused(_ paused: Bool) async {
        guard !isClosed, paused != isPaused else { return }
        isPaused = paused
        if paused {
            if !pending.isEmpty {
                Self.logger.info("送信の一時停止で未送信の \(self.pending.count) 件を捨てた")
            }
            pending.removeAll()
            cancelWake()
            if inFlight == nil {
                await report(.status(.paused))
            }
        } else {
            if inFlight == nil {
                await report(.status(idleStatus))
            }
            evaluate()
        }
    }

    /// 止まっている送信を再開する（「再試行」ボタンや API キーの保存）。
    /// 止まっていた・失敗後の待ちだった場合は、未送信があればすぐに送る。それ以外は通常の条件で判断する。
    public func retryNow() async {
        guard !isClosed, !isFinishing else { return }
        let wasWaitingForRetry = isHalted || retryNotBefore != nil
        isHalted = false
        haltMessage = nil
        haltAction = .checkSettings
        retryNotBefore = nil
        contentFailures = 0
        retryGeneration += 1
        guard inFlight == nil else { return }
        if pending.isEmpty || isPaused || !wasWaitingForRetry {
            await report(.status(idleStatus))
            evaluate()
        } else {
            cancelWake()
            startSend()
        }
    }

    // MARK: - 終了

    /// セッションの終わりに呼ぶ。以後は受け付けない。
    public func finish(_ mode: FinishMode) async {
        guard !isFinishing else {
            // すでに終了処理中（終了前の abort など）。飛行中が終わるのを待つだけ。
            await inFlight?.value
            return
        }
        isFinishing = true
        cancelWake()
        switch mode {
        case .abandon:
            await cancelInFlight()
        case .flush(let timeout):
            let deadline = clock.now() + timeout
            await withTaskGroup(of: FlushOutcome.self) { group in
                group.addTask { await self.flushRemaining(); return .flushed }
                group.addTask {
                    try? await self.clock.sleep(until: deadline)
                    return .timedOut
                }
                if await group.next() == .timedOut {
                    Self.logger.notice("停止時の送信が時間内に終わらないため打ち切る")
                    inFlight?.cancel()
                }
                group.cancelAll()
            }
            await cancelInFlight()
            // 打ち切りや失敗で送れなかった残りがあれば知らせる（一時停止中に捨てたものは除く）。
            if !pending.isEmpty, !isPaused, !isClosed {
                Self.logger.notice("停止時に \(self.pending.count) 件を送れなかった")
                await report(.dropped(pending.count))
            }
        }
        isClosed = true
    }

    /// アプリの終了時など、すぐにやめる。以後は何も送らない（進行中の finish も早く終わる）。
    public func abort() async {
        isFinishing = true
        isClosed = true
        cancelWake()
        await cancelInFlight()
    }

    private enum FlushOutcome: Sendable {
        case flushed, timedOut
    }

    /// 飛行中を待ち、残りを送る。失敗したらそこでやめる（同じものを繰り返さない）。
    private func flushRemaining() async {
        await inFlight?.value
        while !pending.isEmpty, !isPaused, !isHalted, !isClosed, !Task.isCancelled {
            let before = pending.count
            startSend()
            await inFlight?.value
            guard pending.count < before else { break }
        }
    }

    private func cancelInFlight() async {
        guard let inFlight else { return }
        inFlight.cancel()
        // 戻る前に終わるのを待つ（古いエンジンの結果が、次のセッションのノートに届かないように）。
        await inFlight.value
    }

    // MARK: - 送信の判断

    private var pendingCharacters: Int {
        pending.reduce(0) { $0 + $1.text.count }
    }

    /// 送信の条件を見直す。満たしていれば送り、満たしていなければ条件が成り立ちうる時刻に起きる予約をする。
    private func evaluate() {
        guard !isClosed, !isFinishing, inFlight == nil, !isPaused, !isHalted, !pending.isEmpty else {
            cancelWake()
            return
        }
        let interval = pendingCharacters >= configuration.minCharacters ? configuration.minInterval : configuration.maxInterval
        var readyAt = lastCompletedAt + interval
        if let retryNotBefore {
            readyAt = max(readyAt, retryNotBefore)
        }
        if clock.now() >= readyAt {
            cancelWake()
            startSend()
        } else {
            scheduleWake(at: readyAt)
        }
    }

    private func scheduleWake(at time: TimeInterval) {
        guard scheduledWakeAt != time || wakeTask == nil else { return }
        cancelWake()
        wakeGeneration += 1
        let generation = wakeGeneration
        scheduledWakeAt = time
        wakeTask = Task { [clock] in
            do {
                try await clock.sleep(until: time)
            } catch {
                return
            }
            self.wake(generation: generation)
        }
    }

    private func wake(generation: Int) {
        // キャンセルが間に合わずに入ってきた古い予約は捨てる。
        guard generation == wakeGeneration else { return }
        wakeTask = nil
        scheduledWakeAt = nil
        evaluate()
    }

    private func cancelWake() {
        wakeTask?.cancel()
        wakeTask = nil
        scheduledWakeAt = nil
        wakeGeneration += 1
    }

    // MARK: - 送信

    /// 送信を始める。応答の適用・保存・報告まで終えてから inFlight を外す（古い状態が後から届かないように）。
    private func startSend() {
        guard inFlight == nil, !pending.isEmpty else { return }
        inFlight = Task { await self.send() }
    }

    /// 未送信の先頭から上限までをバッチにする。
    private func makeBatch() -> [TranscriptSegment] {
        var batchCount = 0
        var characters = 0
        for segment in pending {
            if batchCount > 0, characters + segment.text.count > configuration.maxBatchCharacters { break }
            batchCount += 1
            characters += segment.text.count
        }
        return Array(pending.prefix(batchCount))
    }

    private func send() async {
        await report(.status(.updating))
        let selection = await modelSelection()
        // ここまでの await の間に一時停止・終了が入った場合は送らない（まだ送っていないので）。
        // バッチもここで切り出す（一時停止で捨てた分を含めないため）。
        guard !isPaused, !isClosed, !Task.isCancelled, !pending.isEmpty else {
            if !isClosed { await report(.status(idleStatus)) }
            return finishSend()
        }
        let batch = makeBatch()
        let sendRetryGeneration = retryGeneration
        do {
            let input = try LiveNotesInput(
                title: configuration.meetingTitle,
                glossary: configuration.glossary,
                notes: notes,
                recentContext: recentContext(),
                segments: batch
            ).jsonString()
            let request = StructuredOutputRequest(
                model: selection.model,
                instructions: systemPrompt,
                input: input,
                schemaName: Self.schemaName,
                schema: schema,
                reasoningEffort: selection.reasoningEffort,
                timeout: configuration.requestTimeout
            )
            let output = try await client.structuredOutput(request)
            let decoded = try NotesOpsResponse.decodeLossy(from: output)
            guard !isClosed, !Task.isCancelled else { return finishSend() }
            if decoded.skippedCount > 0 {
                Self.logger.notice("読めない op を \(decoded.skippedCount) 件捨てた")
            }
            let result = NotesReducer.apply(decoded.ops, to: notes)
            let changed = result.notes != notes
            notes = result.notes
            removeFromPending(batch)
            appendSentTexts(batch)
            contentFailures = 0
            retryNotBefore = nil
            lastCompletedAt = clock.now()
            if changed {
                await persist(notes)
            }
            guard !isClosed else { return finishSend() }
            await report(.applied(result))
            await report(.status(idleStatus))
        } catch is CancellationError {
            // 終了による打ち切り。失敗として扱わない。
        } catch {
            guard !isClosed, !Task.isCancelled else { return finishSend() }
            await handleFailure(error, batch: batch, retriedDuringSend: retryGeneration != sendRetryGeneration)
        }
        finishSend()
    }

    /// 送ったバッチを未送信から除く。一時停止で捨てた後や、その後に届いた分を消さないよう、ID で照らし合わせる。
    @discardableResult
    private func removeFromPending(_ batch: [TranscriptSegment]) -> Int {
        let ids = Set(batch.map(\.id))
        let before = pending.count
        pending.removeAll { ids.contains($0.id) }
        return before - pending.count
    }

    private func finishSend() {
        inFlight = nil
        evaluate()
    }

    /// - Parameter retriedDuringSend: 送信中に「再試行」か資格情報の変更があった。古い資格情報で送ったリクエストの
    ///   失敗で止めないよう、直らない失敗でも止めずに1回だけ送り直す
    private func handleFailure(_ error: any Error, batch: [TranscriptSegment], retriedDuringSend: Bool = false) async {
        let now = clock.now()
        lastCompletedAt = now
        let llmError = error as? LLMError
        let summary = llmError?.logSummary ?? String(describing: type(of: error))
        let message = (error as? LocalizedError)?.errorDescription ?? "ノートを更新できませんでした。"

        switch FailureKind(error) {
        case .permanent where retriedDuringSend:
            // 送信中に接続方法が変わった、などの場合は、新しい資格情報でもう1回だけ試す。
            retryNotBefore = nil
            Self.logger.notice("送信中に再試行が求められたため、止めずに送り直す: \(summary, privacy: .public)")
            await report(.status(idleStatus))
        case .permanent:
            // キーやモデルIDの誤りなど。送り続けても直らないので止める。
            isHalted = true
            haltMessage = message
            haltAction = NotesFailureAction(error)
            Self.logger.error("ノートの更新を止める: \(summary, privacy: .public)")
            await report(.status(idleStatus))
        case .content:
            // 入力の内容で決まる失敗（拒否・出力不正など）。続いたらそのバッチを捨てる。
            contentFailures += 1
            if contentFailures >= configuration.maxContentFailures {
                let count = removeFromPending(batch)
                contentFailures = 0
                // 捨てた分は recent_context にも入れない（拒否の原因を文脈に残さない）。
                Self.logger.error("失敗が続いたため \(count) 件をノートに反映せずに捨てた: \(summary, privacy: .public)")
                await report(.dropped(count))
                // 送り直すものはないので、待機に戻す（反映できなかったことは別の案内で出す）。
                await report(.status(idleStatus))
            } else {
                retryNotBefore = now + configuration.maxInterval
                Self.logger.notice("ノートの更新に失敗。あとで送り直す: \(summary, privacy: .public)")
                await report(.status(isPaused ? .paused : .failed(message: message, needsRetry: false)))
            }
        case .transient:
            // 通信エラーなど。少し待って送り直す（ネットワークが戻ったと分かれば、その時点で送り直す）。
            retryNotBefore = now + configuration.maxInterval
            Self.logger.notice("ノートの更新に失敗。あとで送り直す: \(summary, privacy: .public)")
            let status: LiveNotesStatus = llmError == .network ? .offline : .failed(message: message, needsRetry: false)
            await report(.status(isPaused ? .paused : status))
        }
        // 一時停止中に失敗して戻った分は送らない。
        if isPaused {
            pending.removeAll()
        }
    }

    private enum FailureKind {
        case permanent, content, transient

        init(_ error: any Error) {
            switch error {
            case let error as LLMError:
                switch error {
                case .missingAPIKey, .apiKeyUnavailable, .authentication, .permissionDenied, .quotaExceeded, .badRequest:
                    self = .permanent
                case .failed(let code, _) where LLMError.isTransientFailureCode(code):
                    // ストリームの途中の response.failed などで届くサーバー側の一時的な失敗。発言を捨てない。
                    self = .transient
                case .refusal, .incomplete, .invalidOutput, .failed:
                    self = .content
                case .network, .timeout, .rateLimited, .server, .planUsageUnavailable:
                    self = .transient
                // ChatGPT のプランの利用枠（DESIGN.md §4.11）。時間をおいても直らないので止める。
                case .chatGPTSignInRequired, .chatGPTPlanNotGranted, .chatGPTCredentialUnavailable, .chatGPTUnauthorized,
                     .chatGPTRejected, .usageLimitReached, .planNotEligible, .unsupportedCapability:
                    self = .permanent
                }
            case is DecodingError, is EncodingError:
                self = .content
            default:
                self = .transient
            }
        }
    }

    /// 送信していない間の状態（優先順: 一時停止中 → 止まっている → 待機）
    private var idleStatus: LiveNotesStatus {
        if isPaused { return .paused }
        if isHalted { return .failed(message: haltMessage ?? "ノートを更新できませんでした。", needsRetry: true, action: haltAction) }
        return .waiting
    }

    // MARK: - 手で直す（Phase 6）

    /// 項目の文言を直す。直した項目は固定し、以後のモデルの `update_item` と `remove_item` を無視する。
    public func editItem(id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isClosed, !trimmed.isEmpty, let location = location(ofItem: id) else { return }
        notes.topics[location.topic].items[location.item].text = trimmed
        notes.topics[location.topic].items[location.item].isPinned = true
        await applyManualChange(changed: [id])
    }

    /// 項目を消す（参加者の操作なので、固定の有無によらず消す）。
    public func deleteItem(id: String) async {
        guard !isClosed, let location = location(ofItem: id) else { return }
        notes.topics[location.topic].items.remove(at: location.item)
        await applyManualChange(changed: [])
    }

    private func location(ofItem id: String) -> (topic: Int, item: Int)? {
        for (topicIndex, topic) in notes.topics.enumerated() {
            if let itemIndex = topic.items.firstIndex(where: { $0.id == id }) {
                return (topicIndex, itemIndex)
            }
        }
        return nil
    }

    private func applyManualChange(changed: Set<String>) async {
        await persist(notes)
        await report(.applied(NotesReducer.Result(notes: notes, changedIDs: changed, ignored: [])))
    }

    // MARK: - recent_context

    private func appendSentTexts(_ batch: [TranscriptSegment]) {
        sentTexts.append(contentsOf: batch.map(\.text))
        // recent_context に使うのは末尾の上限分だけなので、古いものは捨てて覚えておく量を抑える。
        var total = sentTexts.reduce(0) { $0 + $1.count }
        while sentTexts.count > 1, total - sentTexts[0].count >= configuration.recentContextLimit {
            total -= sentTexts[0].count
            sentTexts.removeFirst()
        }
    }

    /// 送信に成功した直前の発言。末尾からセグメント単位で上限に収まるだけ取り、1件で超えるときだけ末尾を切り出す。
    private func recentContext() -> String {
        let limit = configuration.recentContextLimit
        guard limit > 0 else { return "" }
        var picked: [String] = []
        var total = 0
        for text in sentTexts.reversed() {
            let separator = picked.isEmpty ? 0 : 1
            if total + separator + text.count > limit { break }
            picked.insert(text, at: 0)
            total += separator + text.count
        }
        if picked.isEmpty, let last = sentTexts.last {
            return String(last.suffix(limit))
        }
        return picked.joined(separator: "\n")
    }
}
