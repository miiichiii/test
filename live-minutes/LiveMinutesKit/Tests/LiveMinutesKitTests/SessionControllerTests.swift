import Foundation
import Testing
@testable import LiveMinutesKit

@MainActor
@Suite("SessionController")
struct SessionControllerTests {
    let source = FakeAudioSource(chunks: [])
    let clock = FakeClock()

    private func makeController(
        engine: ScriptedEngine,
        permission: Bool = true,
        root: URL
    ) -> (SessionController, SessionRepository) {
        let repository = SessionRepository(rootDirectory: root)
        let controller = SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: permission),
            repository: repository,
            clock: clock
        )
        return (controller, repository)
    }

    // MARK: - 基本の流れ

    @Test("開始で録音中になり、停止で最後の確定まで保存して finished になる")
    func startAndStop() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let first = TranscriptSegment(start: 0, end: 2, text: "おはようございます")
        let last = TranscriptSegment(start: 2, end: 4, text: "始めましょう")
        let engine = ScriptedEngine(
            eventsPerStart: [[.volatile("おはよう"), .final(first), .volatile("始め")]],
            eventsOnStop: [.final(last)]
        )
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start(title: "  週次定例 ")
        #expect(controller.state == .recording)
        #expect(controller.problem == nil)
        let meta = try #require(controller.sessionMeta)
        #expect(meta.title == "週次定例")
        #expect(meta.startedAt == clock.date)
        #expect(try await repository.loadMeta(id: meta.id).status == .recording)

        clock.advance(30)
        await controller.stop()
        #expect(controller.state == .finished)
        #expect(controller.transcript.segments == [first, last])
        #expect(controller.transcript.volatileText.isEmpty)
        #expect(await engine.stopCount == 1)

        let saved = try await repository.loadMeta(id: meta.id)
        #expect(saved.status == .finished)
        #expect(saved.duration == 30)
        #expect(try await repository.loadTranscript(id: meta.id).segments == [first, last])
    }

    @Test("会議名を省略すると、開始日時から名前を付ける")
    func defaultTitle() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let (controller, _) = makeController(engine: ScriptedEngine(), root: dir.url)

        await controller.start(title: " ")
        #expect(controller.sessionMeta?.title == SessionController.defaultTitle(for: clock.date))
    }

    @Test("既定の会議名は「年-月-日 時:分 の会議」")
    func defaultTitleFormat() {
        let date = Date(timeIntervalSince1970: 1_763_188_200) // 2025-11-15 06:30 UTC
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(SessionController.defaultTitle(for: date, timeZone: utc) == "2025-11-15 06:30 の会議")
    }

    @Test("準備は最初の開始で1回だけ行う")
    func preparesOnce() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.stop()
        await controller.start()
        await controller.stop()

        #expect(await engine.prepareCount == 1)
        #expect(await engine.startCount == 2)
    }

    @Test("認識言語が変わっていたら、次の開始で準備し直す。同じなら準備しない。再開では変えない")
    func recognitionLocaleChange() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let locale = LocaleHolder(identifier: "ja-JP")
        let controller = SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: SessionRepository(rootDirectory: dir.url),
            clock: clock,
            recognitionLocale: { Locale(identifier: locale.identifier) }
        )

        await controller.start()
        locale.identifier = "en_US"
        await controller.pause()
        await controller.resume()
        await controller.stop()
        #expect(await engine.preparedLocales == ["ja-JP"])

        await controller.start()
        await controller.stop()
        await controller.start()
        await controller.stop()
        #expect(await engine.preparedLocales == ["ja-JP", "en-US"])
    }

    @Test("新しい言語の準備に失敗したら、次の開始でもう一度準備する")
    func retriesPrepareAfterFailure() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let locale = LocaleHolder(identifier: "ja-JP")
        let controller = SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: SessionRepository(rootDirectory: dir.url),
            clock: clock,
            recognitionLocale: { Locale(identifier: locale.identifier) }
        )
        await controller.start()
        await controller.stop()

        locale.identifier = "en-US"
        await engine.setPrepareError(TranscriptionError.modelDownloadFailed("offline"))
        await controller.start()
        #expect(controller.problem == .modelDownloadFailed)

        await engine.setPrepareError(nil)
        await controller.start()
        #expect(controller.state == .recording)
        #expect(await engine.preparedLocales == ["ja-JP", "en-US", "en-US"])
    }

    @Test("finished から開始すると新しいセッションになり、前回の文字起こしは消える")
    func restartFromFinished() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [
            [.final(TranscriptSegment(start: 0, end: 1, text: "一回目"))],
            [.final(TranscriptSegment(start: 0, end: 1, text: "二回目"))],
        ])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.stop()
        let firstID = try #require(controller.sessionMeta?.id)

        await controller.start()
        await controller.stop()
        #expect(controller.sessionMeta?.id != firstID)
        #expect(controller.transcript.segments.map(\.text) == ["二回目"])
    }

    // MARK: - 一時停止

    @Test("一時停止でエンジンを止め、再開で始め直す。再開後の時刻には録音経過時間を足す")
    func pauseAndResume() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [
            [.final(TranscriptSegment(start: 1, end: 3, text: "前半")), .volatile("途中")],
            [.final(TranscriptSegment(start: 0.5, end: 2, text: "後半"))],
        ])
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        clock.advance(10)
        await controller.pause()
        #expect(controller.state == .paused)
        #expect(controller.activity == nil)
        #expect(controller.transcript.volatileText.isEmpty)
        #expect(await engine.isRunning == false)

        // 一時停止中の時間は録音時間に数えない。
        clock.advance(100)
        await controller.resume()
        #expect(controller.state == .recording)
        #expect(await engine.startCount == 2)
        await controller.stop()

        let segments = controller.transcript.segments
        #expect(segments.map(\.text) == ["前半", "後半"])
        #expect(segments[1].start == 10.5)
        #expect(segments[1].end == 12)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadTranscript(id: id).segments == segments)
    }

    @Test("経過時間は一時停止中に進まない")
    func elapsedStopsWhilePaused() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let (controller, repository) = makeController(engine: ScriptedEngine(), root: dir.url)

        await controller.start()
        clock.advance(5)
        #expect(controller.elapsed() == 5)

        await controller.pause()
        clock.advance(60)
        #expect(controller.elapsed() == 5)

        await controller.resume()
        clock.advance(3)
        #expect(controller.elapsed() == 8)

        await controller.stop()
        clock.advance(10)
        #expect(controller.elapsed() == 8)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).duration == 8)
    }

    @Test("再開時のずらし幅は、直前の区間の最後の確定より前にならない")
    func resumeOffsetLowerBound() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        // 経過時間（2秒）より確定の終わり（2.3秒）が後ろにある場合。
        let engine = ScriptedEngine(eventsPerStart: [
            [.final(TranscriptSegment(start: 0, end: 2.3, text: "前半"))],
            [.final(TranscriptSegment(start: 0, end: 1, text: "後半"))],
        ])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        clock.advance(2)
        await controller.pause()
        await controller.resume()
        await controller.stop()

        #expect(controller.transcript.segments[1].start == 2.3)
    }

    @Test("一時停止中に停止すると、そのまま finished になる")
    func stopWhilePaused() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.pause()
        await controller.stop()

        #expect(controller.state == .finished)
        #expect(await engine.startCount == 1)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
    }

    @Test("再開に失敗したら、一時停止のまま問題を表示する")
    func resumeFailureStaysPaused() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.pause()
        await engine.setStartError(AudioSourceError.noInputDevice)
        await controller.resume()

        #expect(controller.state == .paused)
        #expect(controller.problem == .noInputDevice)

        await engine.setStartError(nil)
        await controller.resume()
        #expect(controller.state == .recording)
        #expect(controller.problem == nil)
    }

    // MARK: - 許されない操作

    @Test("idle での停止・一時停止・再開は無視する")
    func ignoredInIdle() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.stop()
        await controller.pause()
        await controller.resume()

        #expect(controller.state == .idle)
        #expect(controller.sessionMeta == nil)
        #expect(await engine.startCount == 0)
        #expect(await engine.stopCount == 0)
    }

    @Test("録音中の開始・再開、一時停止中の一時停止、finished での停止は無視する")
    func ignoredWhileRunning() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        let id = controller.sessionMeta?.id
        await controller.start()
        await controller.resume()
        #expect(controller.state == .recording)
        #expect(controller.sessionMeta?.id == id)
        #expect(await engine.startCount == 1)

        await controller.pause()
        await controller.pause()
        #expect(await engine.stopCount == 1)

        await controller.stop()
        await controller.stop()
        await controller.pause()
        #expect(controller.state == .finished)
        #expect(await engine.stopCount == 1)
    }

    @Test("一時停止の処理中は、ほかの操作を受け付けない")
    func ignoresOperationsWhileBusy() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await engine.holdStop()
        let pausing = Task { await controller.pause() }
        await waitUntil { await engine.stopCount == 1 }
        #expect(controller.activity == .pausing)
        #expect(controller.isBusy)

        await controller.resume()
        await controller.stop()
        #expect(await engine.startCount == 1)

        await engine.releaseStop()
        await pausing.value
        #expect(controller.state == .paused)
        #expect(controller.isBusy == false)
    }

    // MARK: - 失敗

    @Test("マイクの許可がなければ、エンジンを始めずに案内を出す")
    func permissionDenied() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, permission: false, root: dir.url)

        await controller.start()
        #expect(controller.state == .idle)
        #expect(controller.problem == .microphoneDenied)
        #expect(await engine.prepareCount == 0)
        #expect(await engine.startCount == 0)
    }

    @Test("ロケール非対応とモデルのダウンロード失敗は、区別できる問題になる", arguments: [
        (TranscriptionError.unsupportedLocale("ja-JP"), SessionController.Problem.unsupportedLocale),
        (TranscriptionError.modelDownloadFailed("offline"), SessionController.Problem.modelDownloadFailed),
        (TranscriptionError.transcriberUnavailable, SessionController.Problem.transcriberUnavailable),
    ])
    func prepareFailures(error: TranscriptionError, expected: SessionController.Problem) async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(prepareError: error)
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        #expect(controller.state == .idle)
        #expect(controller.problem == expected)
        #expect(await engine.startCount == 0)
        // 失敗した開始ではフォルダを作らない。
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path(percentEncoded: false)).isEmpty)
    }

    @Test("finished から開始に失敗したら、finished と前回の文字起こしを残す")
    func failedRestartKeepsPreviousSession() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(TranscriptSegment(start: 0, end: 1, text: "前回"))]])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.stop()
        await engine.setStartError(AudioSourceError.noInputDevice)
        await controller.start()

        #expect(controller.state == .finished)
        #expect(controller.problem == .noInputDevice)
        #expect(controller.transcript.segments.map(\.text) == ["前回"])
    }

    @Test("セッションのフォルダを作れなければ、エンジンを止めて保存の失敗を表示する")
    func createSessionFailure() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        // 保存先の場所に普通のファイルを置き、フォルダを作れないようにする。
        let blocked = dir.url.appending(path: "blocked")
        try Data().write(to: blocked)
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: blocked)

        await controller.start()
        #expect(controller.state == .idle)
        #expect(controller.problem == .saveFailed)
        #expect(await engine.isRunning == false)
        #expect(controller.sessionMeta == nil)
    }

    @Test("録音中に認識が失敗したら、そこまでを保存して finished になり、問題を表示する")
    func failureDuringRecording() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let segment = TranscriptSegment(start: 0, end: 1, text: "ここまで")
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment), .volatile("途中")]])
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await engine.failDuringRecording(AudioSourceError.noInputDevice)
        await controller.waitForEventsAndSettle()

        #expect(controller.state == .finished)
        #expect(controller.problem == .noInputDevice)
        #expect(controller.transcript.volatileText.isEmpty)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
        #expect(try await repository.loadTranscript(id: id).segments == [segment])
    }

    @Test("停止操作なしにエラーなしで終わった場合も、認識の途中終了として finished にする")
    func streamEndsWithoutError() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await engine.finishWithoutError()
        await controller.waitForEventsAndSettle()

        #expect(controller.state == .finished)
        #expect(controller.problem == .other(TranscriptionError.recognitionEnded.localizedDescription))
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
    }

    @Test("認識の失敗の直後に停止・一時停止を押しても、finished になり保存される", arguments: [true, false])
    func failureRacesWithOperation(pressStop: Bool) async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let segment = TranscriptSegment(start: 0, end: 1, text: "ここまで")
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment)]])
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await engine.failDuringRecording(AudioSourceError.noInputDevice)
        if pressStop {
            await controller.stop()
        } else {
            await controller.pause()
        }
        await controller.waitForEventsAndSettle()
        #expect(controller.isBusy == false)

        if !pressStop {
            // 一時停止が失敗の処理より先に通った場合は、一時停止のまま問題を表示する（再開の失敗と同じ扱い）。
            // 失敗の処理が先なら finished になっている。どちらでも停止すれば保存を終えられる。
            #expect(controller.state == .paused || controller.state == .finished)
            #expect(controller.problem == .noInputDevice)
            await controller.stop()
        }
        #expect(controller.state == .finished)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
        #expect(try await repository.loadTranscript(id: id).segments == [segment])
    }

    @Test("追記に失敗しても文字起こしは続け、警告を1回だけ出す。終了時に meta を書けなければ保存の失敗を出す")
    func saveFailuresDuringRecording() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        let id = try #require(controller.sessionMeta?.id)
        // セッションのフォルダを消して、追記と meta.json の書き込みを失敗させる。
        try FileManager.default.removeItem(at: repository.directory(for: id))

        await engine.emit(.final(TranscriptSegment(start: 0, end: 1, text: "一件目")))
        await engine.emit(.final(TranscriptSegment(start: 1, end: 2, text: "二件目")))
        await waitUntil { controller.transcript.segments.count == 2 }
        #expect(controller.state == .recording)
        #expect(controller.warning == .transcriptNotSaved)
        #expect(controller.problem == nil)

        await controller.stop()
        #expect(controller.state == .finished)
        #expect(controller.problem == .saveFailed)
        #expect(controller.transcript.segments.count == 2)
    }

    @Test("再開に失敗した後に停止して保存できたら、案内を消す")
    func stopClearsResumeProblem() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.pause()
        await engine.setStartError(AudioSourceError.noInputDevice)
        await controller.resume()
        #expect(controller.problem == .noInputDevice)

        await controller.stop()
        #expect(controller.state == .finished)
        #expect(controller.problem == nil)
    }

    // MARK: - アプリの終了

    @Test("開始の処理中はほかの操作を受け付けず、終了前の処理は開始を待ってから停止する")
    func terminationWaitsForStart() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await engine.holdStart()
        let starting = Task { await controller.start() }
        await waitUntil { await engine.startCount == 1 }
        #expect(controller.state == .preparing(progress: nil) || controller.state == .preparing(progress: 0.5))
        #expect(controller.activity == .starting)
        #expect(controller.needsFinishingBeforeTermination)

        await controller.stop()
        await controller.pause()
        await controller.start()
        #expect(await engine.startCount == 1)

        let terminating = Task { await controller.finishForTermination() }
        await engine.releaseStart()
        await starting.value
        await terminating.value

        #expect(controller.state == .finished)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
    }

    @Test("終了前の処理は、録音中なら停止して保存を終える")
    func terminationWhileRecording() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let (controller, repository) = makeController(engine: ScriptedEngine(), root: dir.url)

        await controller.start()
        #expect(controller.needsFinishingBeforeTermination)
        await controller.finishForTermination()

        #expect(controller.state == .finished)
        #expect(controller.needsFinishingBeforeTermination == false)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
    }

    @Test("終了前の処理は、一時停止の処理中ならそれを待ってから停止する")
    func terminationWaitsForPause() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await engine.holdStop()
        let pausing = Task { await controller.pause() }
        await waitUntil { await engine.stopCount == 1 }

        let terminating = Task { await controller.finishForTermination() }
        await engine.releaseStop()
        await pausing.value
        await terminating.value

        #expect(controller.state == .finished)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
    }

    @Test("終了前の処理は、待機中なら何もしない")
    func terminationWhileIdle() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let (controller, _) = makeController(engine: ScriptedEngine(), root: dir.url)

        #expect(controller.needsFinishingBeforeTermination == false)
        await controller.finishForTermination()
        #expect(controller.state == .idle)
    }
}

@MainActor
@Suite("TranscriptStore")
struct TranscriptStoreTests {
    @Test("未確定は置き換え、確定で追加して未確定を消す")
    func appliesEvents() {
        let store = TranscriptStore()
        store.apply(.volatile("じゃあ"))
        store.apply(.volatile("じゃあリリースは"))
        #expect(store.volatileText == "じゃあリリースは")
        #expect(store.segments.isEmpty)

        let segment = TranscriptSegment(start: 0, end: 2, text: "じゃあリリースは来週にしましょう")
        store.apply(.final(segment))
        #expect(store.segments == [segment])
        #expect(store.volatileText.isEmpty)

        store.apply(.volatile("佐藤さん"))
        store.clearVolatile()
        #expect(store.volatileText.isEmpty)
        #expect(store.segments.count == 1)

        store.reset()
        #expect(store.segments.isEmpty)
    }
}

/// テストの途中で認識言語を変えるための入れ物。
@MainActor
final class LocaleHolder {
    var identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }
}
