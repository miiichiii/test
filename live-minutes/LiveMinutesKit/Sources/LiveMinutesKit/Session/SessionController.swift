import Foundation
import Observation
import os

/// 1回の会議（セッション）の進行を束ねる（DESIGN.md §4.10）。View はこれと `TranscriptStore` を読むだけにする。
///
/// 状態: `idle` → `preparing` → `recording` ⇄ `paused` → `finishing` → `finished`。
/// `finished` から開始すると、新しいセッションになる。許されない操作は何もせずに無視する。
///
/// 一時停止は文字起こしエンジンの `stop()`、再開は `start(source:)` で行う。一時停止の時点で未確定分まで確定し、
/// その間はマイクを止める。エンジンは開始のたびに時刻を0から数えるので、再開後のセグメントには
/// 再開時点の録音経過時間を足してから表示・保存する。
@MainActor
@Observable
public final class SessionController {
    public enum State: Equatable, Sendable {
        case idle
        /// 権限の確認やモデルの準備中。ダウンロード中は進捗（0…1）を持つ
        case preparing(progress: Double?)
        case recording
        case paused
        /// 最後の未確定分を確定させ、保存している
        case finishing
        /// 停止して保存を終えた。文字起こしは表示したまま
        case finished
    }

    /// 処理中の操作。この間はほかの操作を受け付けない（公開する状態とは別に持つ）。
    public enum Activity: Equatable, Sendable {
        case starting, pausing, resuming, stopping
    }

    public enum Problem: Equatable, Sendable {
        case microphoneDenied
        case noInputDevice
        case transcriberUnavailable
        case unsupportedLocale
        case modelDownloadFailed
        case saveFailed
        case other(String)

        /// 画面に出す説明
        public var message: String {
            switch self {
            case .microphoneDenied:
                "マイクの使用が許可されていません。システム設定の「プライバシーとセキュリティ」→「マイク」で LiveMinutes を許可してください。"
            case .noInputDevice:
                "マイクが見つかりません。マイクをつないでから、もう一度開始してください。"
            case .transcriberUnavailable:
                "この Mac では端末内の音声認識を使えません。"
            case .unsupportedLocale:
                "日本語の音声認識に対応していません。"
            case .modelDownloadFailed:
                "音声認識モデルのダウンロードに失敗しました。ネットワークを確認して、もう一度開始してください。"
            case .saveFailed:
                "セッションを保存できませんでした。ディスクの空き容量を確認してください。"
            case .other(let detail):
                "文字起こしを続けられませんでした（\(detail)）。もう一度開始してください。"
            }
        }

        init(_ error: any Error) {
            switch error {
            case AudioSourceError.noInputDevice:
                self = .noInputDevice
            case TranscriptionError.transcriberUnavailable:
                self = .transcriberUnavailable
            case TranscriptionError.unsupportedLocale:
                self = .unsupportedLocale
            case TranscriptionError.modelDownloadFailed:
                self = .modelDownloadFailed
            default:
                self = .other(error.localizedDescription)
            }
        }
    }

    /// 文字起こしは続けられるが、知らせておくこと。
    public enum Warning: Equatable, Sendable {
        /// `transcript.jsonl` への追記に失敗した
        case transcriptNotSaved

        public var message: String {
            switch self {
            case .transcriptNotSaved:
                "文字起こしの一部を保存できませんでした。画面の内容は残っているので、停止後に書き出してください。"
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var activity: Activity?
    public private(set) var problem: Problem?
    public private(set) var warning: Warning?
    /// 現在の（停止後は直前の）セッション。会議名と開始日時を画面と書き出しに使う
    public private(set) var sessionMeta: SessionMeta?
    public let transcript = TranscriptStore()
    /// 入力レベル（0…1）
    public private(set) var inputLevel: Float = 0

    private let engine: any TranscriptionEngine
    private let source: any AudioSource
    private let permission: any MicrophonePermission
    private let repository: SessionRepository
    private let clock: any SessionClock

    private var isPrepared = false
    /// 録音中・一時停止中のセッション。終了処理を始めた時点で nil にする（終了処理を二重に走らせないため）
    private var activeSessionID: UUID?
    /// これまでの録音区間の合計（秒）
    private var accumulated: TimeInterval = 0
    /// 今の録音区間を始めたときの `clock.uptime()`。録音中だけ値を持つ
    private var runStartedAt: TimeInterval?
    /// 最後に確定したセグメントの終わり（録音経過時間）
    private var lastFinalEnd: TimeInterval = 0
    /// 一時停止・停止の操作でイベントのストリームを終わらせている間は true。false のときに終われば失敗
    private var expectingStreamEnd = false

    private var eventsTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var failureTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Session")

    public init(
        engine: any TranscriptionEngine,
        source: any AudioSource,
        permission: any MicrophonePermission,
        repository: SessionRepository,
        clock: any SessionClock
    ) {
        self.engine = engine
        self.source = source
        self.permission = permission
        self.repository = repository
        self.clock = clock
    }

    // MARK: - 画面から読む値

    /// 操作を受け付けない間は true
    public var isBusy: Bool { activity != nil }

    /// 録音経過時間（一時停止中は進まない）
    public func elapsed() -> TimeInterval {
        accumulated + (runStartedAt.map { max(clock.uptime() - $0, 0) } ?? 0)
    }

    /// 終了の前に、最終確定と保存を待つ必要があるか
    public var needsFinishingBeforeTermination: Bool {
        operation != nil || activeSessionID != nil
    }

    /// 会議名を省略したときの名前（例: 「2026-11-15 14:30 の会議」）
    public static func defaultTitle(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) の会議"
    }

    // MARK: - 操作

    /// 新しいセッションを始める。`idle` か `finished` のときだけ受け付ける。
    /// - Parameter title: 会議名。空白だけなら日時から自動で付ける
    public func start(title: String = "") async {
        guard operation == nil, state == .idle || state == .finished else { return }
        await perform(.starting) { await self.runStart(title: title) }
    }

    /// 録音中のときだけ受け付ける。
    public func pause() async {
        guard operation == nil, state == .recording else { return }
        await perform(.pausing) { await self.runPause() }
    }

    /// 一時停止中のときだけ受け付ける。再開できなかった場合は一時停止のまま問題を表示する。
    public func resume() async {
        guard operation == nil, state == .paused else { return }
        await perform(.resuming) { await self.runResume() }
    }

    /// 録音中か一時停止中のときだけ受け付ける。
    public func stop() async {
        guard operation == nil, state == .recording || state == .paused else { return }
        await perform(.stopping) {
            // 再開の失敗などで出ていた案内は、停止して保存できれば不要なので消す（保存の失敗は改めて出す）。
            self.problem = nil
            await self.finishSession()
        }
    }

    /// アプリの終了前に呼ぶ。処理中の操作を待ち、録音中・一時停止中なら停止して保存を終える。
    public func finishForTermination() async {
        while true {
            if let operation {
                await operation.value
                continue
            }
            if activeSessionID != nil, state == .recording || state == .paused {
                await perform(.stopping) { await self.finishSession() }
                continue
            }
            return
        }
    }

    // MARK: - 操作の中身

    /// 操作を1つずつ実行する。終わるまで `operation` と `activity` を持ち、その間はほかの操作を無視する。
    private func perform(_ activity: Activity, _ body: @escaping @MainActor () async -> Void) async {
        let task = Task { @MainActor in
            await body()
            // 待っている側が再開する前に片付けるよう、Task の中で消す。
            self.operation = nil
            self.activity = nil
        }
        // Task の本体はこの関数が await するまで始まらないので、ここで代入すれば間に合う。
        operation = task
        self.activity = activity
        await task.value
    }

    private func runStart(title: String) async {
        let previous = state
        problem = nil
        state = .preparing(progress: nil)
        startLevelMonitoringIfNeeded()

        // 未決定のままエンジンを始めると無音になるので、必ず先に許可を確かめる。
        guard await permission.requestAccessIfNeeded() else {
            problem = .microphoneDenied
            state = previous
            return
        }

        let events: AsyncThrowingStream<TranscriptEvent, any Error>
        do {
            if !isPrepared {
                try await engine.prepare { [weak self] value in
                    Task { @MainActor in self?.updatePreparingProgress(value) }
                }
                isPrepared = true
            }
            events = try await engine.start(source: source)
        } catch {
            problem = Problem(error)
            state = previous
            return
        }

        // フォルダは開始に成功してから作る（失敗した開始で空のフォルダを残さない）。
        let now = clock.now()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = SessionMeta(title: trimmed.isEmpty ? Self.defaultTitle(for: now) : trimmed, startedAt: now)
        do {
            try await repository.createSession(meta)
        } catch {
            Self.logger.error("セッションを作れない: \(String(describing: error), privacy: .public)")
            expectingStreamEnd = true
            await engine.stop()
            problem = .saveFailed
            state = previous
            return
        }

        transcript.reset()
        warning = nil
        sessionMeta = meta
        activeSessionID = meta.id
        accumulated = 0
        lastFinalEnd = 0
        runStartedAt = clock.uptime()
        expectingStreamEnd = false
        state = .recording
        eventsTask = makeEventsTask(events, offset: 0, sessionID: meta.id)
    }

    private func runPause() async {
        freezeElapsed()
        expectingStreamEnd = true
        state = .paused
        // 一時停止の時点までを確定させる。イベントを読み終えてから次の操作を受け付ける。
        await engine.stop()
        await eventsTask?.value
        eventsTask = nil
        transcript.clearVolatile()
        inputLevel = 0
    }

    private func runResume() async {
        guard let sessionID = activeSessionID else { return }
        problem = nil
        guard await permission.requestAccessIfNeeded() else {
            problem = .microphoneDenied
            return
        }
        // 壁時計の経過時間を基準にし、直前の区間の最後の確定より前にはならないようにする
        // （停止を押してからマイクが止まるまでの分だけ、確定の終わりが経過時間を超えることがあるため）。
        let offset = max(accumulated, lastFinalEnd)
        do {
            let events = try await engine.start(source: source)
            accumulated = offset
            runStartedAt = clock.uptime()
            expectingStreamEnd = false
            state = .recording
            eventsTask = makeEventsTask(events, offset: offset, sessionID: sessionID)
        } catch {
            problem = Problem(error)
        }
    }

    /// セッションを終える。停止操作・認識の失敗・アプリの終了のどれからも、ここを通る。
    private func finishSession() async {
        guard activeSessionID != nil, var meta = sessionMeta else {
            // 通常は起きない。終了前の処理が空回りしないよう、セッションなしの状態にそろえる。
            activeSessionID = nil
            return
        }
        // 最初の await より前に消して、二重に走らないようにする。
        activeSessionID = nil
        freezeElapsed()
        expectingStreamEnd = true
        state = .finishing

        // 一時停止中や認識の失敗後は、エンジンはすでに止まっている（その場合 stop は何もしない）。
        await engine.stop()
        // イベントの Task はキャンセルしない（保存前の確定が落ちるため）。ストリームの終わりで自然に終わらせる。
        await eventsTask?.value
        eventsTask = nil
        transcript.clearVolatile()
        inputLevel = 0

        meta.duration = accumulated
        meta.status = .finished
        do {
            try await repository.writeMeta(meta)
        } catch {
            Self.logger.error("meta.json を書けない: \(String(describing: error), privacy: .public)")
            if problem == nil {
                problem = .saveFailed
            }
        }
        await repository.closeTranscript(for: meta.id)
        sessionMeta = meta
        state = .finished
    }

    // MARK: - イベント

    /// - Parameter offset: この区間のセグメントに足す秒数。作るときに決めて渡す（届いたときに可変の状態を読まない）
    private func makeEventsTask(
        _ events: AsyncThrowingStream<TranscriptEvent, any Error>,
        offset: TimeInterval,
        sessionID: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await event in events {
                    // 保存の順序を保つため、1件ずつ待ってから次を読む。
                    await self?.handle(event, offset: offset, sessionID: sessionID)
                }
                self?.eventsDidEnd(error: nil)
            } catch {
                self?.eventsDidEnd(error: error)
            }
        }
    }

    private func handle(_ event: TranscriptEvent, offset: TimeInterval, sessionID: UUID) async {
        guard case .final(let segment) = event else {
            transcript.apply(event)
            return
        }
        let shifted = TranscriptSegment(
            id: segment.id,
            start: segment.start + offset,
            end: segment.end + offset,
            text: segment.text
        )
        transcript.apply(.final(shifted))
        lastFinalEnd = max(lastFinalEnd, shifted.end)
        do {
            try await repository.appendSegment(shifted, to: sessionID)
        } catch {
            // 文字起こしは続ける。知らせるのはセッションごとに1回だけ。
            if warning == nil {
                Self.logger.error("transcript.jsonl に追記できない: \(String(describing: error), privacy: .public)")
                warning = .transcriptNotSaved
            }
        }
    }

    private func eventsDidEnd(error: (any Error)?) {
        if let error {
            problem = Problem(error)
        }
        guard !expectingStreamEnd else { return }
        // 停止操作によらずに終わった（認識の失敗など）。エンジンはソースを止めているので、そこまでを保存して終える。
        if error == nil {
            problem = Problem(TranscriptionError.recognitionEnded)
        }
        expectingStreamEnd = true
        failureTask = Task { [weak self] in
            guard let self else { return }
            while let operation = self.operation {
                await operation.value
            }
            if self.activeSessionID != nil, self.state == .recording || self.state == .paused {
                await self.perform(.stopping) { await self.finishSession() }
            }
            self.failureTask = nil
        }
    }

    // MARK: - 内部

    private func freezeElapsed() {
        guard let runStartedAt else { return }
        accumulated += max(clock.uptime() - runStartedAt, 0)
        self.runStartedAt = nil
    }

    private func updatePreparingProgress(_ value: Double) {
        guard case .preparing = state else { return }
        state = .preparing(progress: min(max(value, 0), 1))
    }

    private func startLevelMonitoringIfNeeded() {
        guard levelTask == nil else { return }
        let levels = source.levels
        levelTask = Task { [weak self] in
            for await level in levels {
                self?.inputLevel = level
            }
        }
    }

    // MARK: - テスト用

    /// イベントの読み取りと、それに続く処理（認識の失敗による終了など）が終わるまで待つ。
    /// 録音中にストリームが終わらない場合は戻らないので、ストリームを終わらせてから呼ぶ。
    func waitForEventsAndSettle() async {
        await eventsTask?.value
        while true {
            if let operation {
                await operation.value
                continue
            }
            if let failureTask {
                await failureTask.value
                continue
            }
            return
        }
    }
}
