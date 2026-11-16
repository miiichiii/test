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
                "選んだ言語の音声認識に対応していません。設定画面で別の言語を選んでください。"
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

    public private(set) var state: State = .idle {
        // 録音中（と、議事録を作っている確定中）はスリープさせない。ほかの状態に移ったら必ず解除する（失敗の場合も）。
        didSet { sleepPreventer?.setPreventsSleep(state == .recording || state == .finishing) }
    }
    public private(set) var activity: Activity?
    public private(set) var problem: Problem?
    public private(set) var warning: Warning?
    /// 現在の（停止後は直前の）セッション。会議名と開始日時を画面と書き出しに使う
    public private(set) var sessionMeta: SessionMeta?
    public let transcript = TranscriptStore()
    /// ライブ更新のノートと状態
    public let notes = NotesStore()
    /// 議事録（Phase 5。DESIGN.md §4.6）
    public let minutes: MinutesStore
    private let glossary: @MainActor () -> [String]
    private let sleepPreventer: (any SleepPreventing)?
    /// 入力レベル（0…1）
    public private(set) var inputLevel: Float = 0

    private let engine: any TranscriptionEngine
    private let source: any AudioSource
    private let permission: any MicrophonePermission
    private let repository: SessionRepository
    private let clock: any SessionClock
    private let recognitionLocale: @MainActor () -> Locale
    private let notesEngineFactory: (@MainActor (SessionMeta, NotesStore) async -> NotesEngine?)?

    /// 停止時に、ノートの残りの送信を待つ上限（秒）
    static let notesFlushTimeout: TimeInterval = 15

    /// 準備を済ませたロケール（BCP 47）。設定で変わっていたら、次のセッションの開始時に準備し直す
    private var preparedLocaleIdentifier: String?
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
    /// 今のセッションのライブ更新。API キーがなければ nil
    private var notesEngine: NotesEngine?
    /// 一時停止トグルの変更をエンジンへ順に伝える
    private var notesPauseTask: Task<Void, Never>?
    /// ライブ更新のエンジンを作っている処理（キーチェーンの許可ダイアログを待つことがあるので、会議の開始とは別に走らせる）
    private var notesAttachTask: Task<Void, Never>?
    /// エンジンを作っているセッション（付けた直後に、ためた発言を渡し終えるまでを含む）。
    /// セッションで見分けるのは、前の会議のエンジン作りが終わる前に次の会議を始めても取り違えないため
    private var attachingSessionID: UUID?
    /// エンジンを作っている間に確定した発言。付けたら順に渡す（ダイアログの間の発言もノートに入れるため）
    private var notesBuffer: [TranscriptSegment] = []
    /// エンジンを作っている間に資格情報が変わった。作れなかったら、もう一度試す
    private var notesReattachRequested = false
    /// 一時停止トグルをオンにするたびに進める。ためた発言を渡している途中でオンになったら、残りを渡さないため
    private var notesPauseGeneration = 0

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "Session")

    public init(
        engine: any TranscriptionEngine,
        source: any AudioSource,
        permission: any MicrophonePermission,
        repository: SessionRepository,
        clock: any SessionClock,
        recognitionLocale: @escaping @MainActor () -> Locale = { Locale(identifier: "ja-JP") },
        notesEngineFactory: (@MainActor (SessionMeta, NotesStore) async -> NotesEngine?)? = nil,
        minutesGenerator: (any MinutesGenerating)? = nil,
        glossary: @escaping @MainActor () -> [String] = { [] },
        sleepPreventer: (any SleepPreventing)? = nil
    ) {
        self.engine = engine
        self.source = source
        self.permission = permission
        self.repository = repository
        self.clock = clock
        self.recognitionLocale = recognitionLocale
        self.notesEngineFactory = notesEngineFactory
        self.minutes = MinutesStore(generator: minutesGenerator, repository: repository)
        self.glossary = glossary
        self.sleepPreventer = sleepPreventer
    }

    // MARK: - 画面から読む値

    /// 操作を受け付けない間は true
    public var isBusy: Bool { activity != nil }

    /// 今受け付ける操作（メニューバーとショートカットの有効・無効に使う。Phase 6）
    public var canStart: Bool { operation == nil && (state == .idle || state == .finished) }
    public var canPause: Bool { operation == nil && state == .recording }
    public var canResume: Bool { operation == nil && state == .paused }
    public var canStop: Bool { operation == nil && (state == .recording || state == .paused) }

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
    /// ノートの残りは送らない（終了の上限時間に収めるため）。
    public func finishForTermination() async {
        // 停止処理がノートの送信や議事録の生成を待っている最中でも、すぐに抜けられるようにする（議事録は保存しない）。
        minutes.cancel()
        await notesEngine?.abort()
        while true {
            if let operation {
                await operation.value
                continue
            }
            if activeSessionID != nil, state == .recording || state == .paused {
                await perform(.stopping) { await self.finishSession(notesMode: .abandon) }
                continue
            }
            return
        }
    }

    // MARK: - 議事録

    /// 議事録の生成を止める（停止の後の生成中に、利用者が「中止」を押したとき）。不完全な内容は保存しない
    public func cancelMinutes() {
        minutes.cancel()
    }

    /// 終わった今のセッションの議事録を作り直す。
    public func regenerateMinutes() async {
        guard state == .finished, operation == nil, let meta = sessionMeta else { return }
        await minutes.generate(meta: meta, segments: transcript.segments, notes: notes.notes, glossary: glossary())
    }

    // MARK: - ライブ更新

    /// 「要約の送信を一時停止」を切り替える。オンの間に確定した発言は LLM に送らず、オフに戻しても送らない。
    /// オンにした時点でまだ送っていない発言も捨てる（文字起こしには残る）。
    public func setNotesSendingPaused(_ paused: Bool) {
        guard notes.isSendingPaused != paused else { return }
        notes.isSendingPaused = paused
        // まだエンジンに渡していない発言も、オンにした時点で捨てる。
        if paused {
            notesBuffer.removeAll()
            notesPauseGeneration += 1
        }
        guard let engine = notesEngine else { return }
        // 切り替えの順序を保つため、前の変更を待ってから伝える。
        let previous = notesPauseTask
        notesPauseTask = Task {
            await previous?.value
            await engine.setPaused(paused)
        }
    }

    /// ネットワークにつながった（Phase 6）。オフラインで待っていた送信を、すぐに送り直す。
    public func networkDidBecomeAvailable() {
        guard notes.status == .offline else { return }
        retryNotes()
    }

    /// ノートの項目を手で直す（Phase 6）。会議中（ライブ更新が動いている間）だけ
    public func editNoteItem(id: String, text: String) {
        guard let engine = notesEngine else { return }
        Task { await engine.editItem(id: id, text: text) }
    }

    /// ノートの項目を手で消す（Phase 6）
    public func deleteNoteItem(id: String) {
        guard let engine = notesEngine else { return }
        Task { await engine.deleteItem(id: id) }
    }

    /// ノートを手で直せるか（ライブ更新が動いている会議中だけ）
    public var canEditNotes: Bool { notesEngine != nil }

    /// ライブ更新の「再試行」。止まっている送信を再開する。
    public func retryNotes() {
        guard let engine = notesEngine else { return }
        Task { await engine.retryNow() }
    }

    /// 資格情報が変わったとき（API キーの保存・削除、ChatGPT のログイン・ログアウト、接続方法の変更）に呼ぶ。
    /// 止まっていた送信を再開し、会議中に設定されたらその時点からライブ更新を始める。
    ///
    /// エンジンを作っている途中なら、終わったらもう一度試すよう頼むだけで、待たずに戻る。
    /// そうでなければ、エンジンを作り終えるまで待つ。
    public func credentialsDidChange() async {
        if let engine = notesEngine {
            await engine.retryNow()
            return
        }
        guard activeSessionID != nil, let meta = sessionMeta else { return }
        if attachingSessionID == meta.id {
            notesReattachRequested = true
            return
        }
        startAttachingNotesEngine(for: meta)
        await notesAttachTask?.value
    }

    /// ライブ更新のエンジンを、会議の開始とは別の Task で作り始める（DESIGN.md §4.10）。
    ///
    /// ChatGPT のプランでは「設定済みか」を確かめるときにキーチェーンを読むので、許可ダイアログが出うる。
    /// その間も録音と文字起こしは進め、確定した発言はためておいて、付けたときに順に渡す。
    private func startAttachingNotesEngine(for meta: SessionMeta) {
        guard attachingSessionID != meta.id else {
            notesReattachRequested = true
            return
        }
        attachingSessionID = meta.id
        notesBuffer.removeAll()
        notesReattachRequested = false
        notesAttachTask = Task { [weak self] in
            await self?.attachNotesEngine(for: meta)
        }
    }

    /// ライブ更新のエンジンを作って付ける。作れなければ（未設定）その旨を表示する。
    private func attachNotesEngine(for meta: SessionMeta) async {
        defer {
            // 次の会議のエンジン作りが始まっていたら、そちらの状態には触れない。
            if attachingSessionID == meta.id {
                notesBuffer.removeAll()
                attachingSessionID = nil
                notesAttachTask = nil
            }
        }
        while true {
            notesReattachRequested = false
            let engine = await notesEngineFactory?(meta, notes)
            // 待っている間にセッションが終わった、または別の経路でエンジンができた場合は使わない。
            guard activeSessionID == meta.id, notesEngine == nil else {
                await engine?.abort()
                return
            }
            guard let engine else {
                notes.status = .notConfigured
                // 作っている間に資格情報が変わっていたら、もう一度試す。
                if notesReattachRequested { continue }
                return
            }
            notesEngine = engine
            // 待っている間に一時停止トグルがオンになっていたら、エンジンにも伝える。
            if notes.isSendingPaused {
                notes.status = .paused
                notesBuffer.removeAll()
                await engine.setPaused(true)
            } else {
                notes.status = .waiting
            }
            // ためた発言を順に渡す。渡している間に届いた発言もためるので、空になるまで繰り返す。
            // 途中で一時停止トグルがオンになったら、残りは渡さない（オンにした時点でまだ送っていない発言は捨てる）。
            let pauseGeneration = notesPauseGeneration
            flush: while !notesBuffer.isEmpty {
                let buffered = notesBuffer
                notesBuffer.removeAll()
                for segment in buffered {
                    guard notesPauseGeneration == pauseGeneration else { break flush }
                    await engine.add(segment)
                }
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
            // 認識言語は新しいセッションの開始時にだけ反映する（再開では変えない）。
            let locale = recognitionLocale()
            let localeIdentifier = locale.identifier(.bcp47)
            if preparedLocaleIdentifier != localeIdentifier {
                preparedLocaleIdentifier = nil
                try await engine.prepare(locale: locale) { [weak self] value in
                    Task { @MainActor in self?.updatePreparingProgress(value) }
                }
                preparedLocaleIdentifier = localeIdentifier
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
        notes.reset()
        minutes.reset()
        warning = nil
        sessionMeta = meta
        activeSessionID = meta.id
        accumulated = 0
        lastFinalEnd = 0
        runStartedAt = clock.uptime()
        expectingStreamEnd = false
        state = .recording
        eventsTask = makeEventsTask(events, offset: 0, sessionID: meta.id)
        // 未設定ならライブ更新は動かさず、文字起こしだけを続ける。会議の開始を待たせないよう、別の Task で作る。
        startAttachingNotesEngine(for: meta)
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
    /// 順序: 最終確定 → meta.json と transcript.jsonl を閉じる → ノートの残りを送る（上限つき）→ finished。
    /// 保存を先に済ませるのは、ノートを待っている間に終了しても meta.json を finished にしておくため。
    private func finishSession(notesMode: NotesEngine.FinishMode = .flush(timeout: SessionController.notesFlushTimeout)) async {
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

        // ためた発言をエンジンに渡している途中なら、渡し終えるまで待つ（actor への数回の呼び出しなので短い）。
        // エンジンを作っている途中（キーチェーンのダイアログ待ちなど）なら、待たずに打ち切る
        // （作り終えたエンジンは、セッションが変わったので捨てられる）。
        if notesEngine != nil, attachingSessionID == meta.id {
            await notesAttachTask?.value
        }
        attachingSessionID = nil
        notesBuffer.removeAll()
        notesAttachTask = nil
        await notesPauseTask?.value
        notesPauseTask = nil
        if let engine = notesEngine {
            await engine.finish(notesMode)
            notesEngine = nil
        }
        notes.status = .inactive

        // 議事録（Phase 5）。最終確定 → 残りのライブ更新 → 議事録の順。失敗してもセッションは finished にする
        // （後から「作り直す」で作れる）。アプリの終了時は作らない。
        if case .flush = notesMode {
            await minutes.generate(meta: meta, segments: transcript.segments, notes: notes.notes, glossary: glossary())
        }
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
        // 「要約の送信を一時停止」がオンの間に確定した発言は、ノートの更新に渡さない（後からも送らない）。
        let sendToNotes = !notes.isSendingPaused
        do {
            try await repository.appendSegment(shifted, to: sessionID)
        } catch {
            // 文字起こしは続ける。知らせるのはセッションごとに1回だけ。
            if warning == nil {
                Self.logger.error("transcript.jsonl に追記できない: \(String(describing: error), privacy: .public)")
                warning = .transcriptNotSaved
            }
        }
        if sendToNotes {
            if attachingSessionID == sessionID {
                notesBuffer.append(shifted)
            } else if let engine = notesEngine {
                await engine.add(shifted)
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

    /// 一時停止トグルの変更がエンジンに伝わるまで待つ。
    func waitForNotesPauseChange() async {
        await notesPauseTask?.value
    }

    /// ライブ更新のエンジンを作り終えるまで待つ。
    func waitForNotesAttach() async {
        await notesAttachTask?.value
    }

    /// エンジンを作っている間にためている発言の数
    var notesBufferCount: Int { notesBuffer.count }

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
