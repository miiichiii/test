import Foundation
import Testing
@testable import LiveMinutesKit

@MainActor
final class FakeAutoPauseNotifier: AutoPauseNotifying {
    private(set) var notified: [TimeInterval] = []

    func notifyAutoPaused(after silence: TimeInterval) {
        notified.append(silence)
    }
}

/// 無音が続いたときの自動一時停止。時計は手で進め、確かめる処理（`checkSilence`）は直接呼ぶ。
@MainActor
@Suite("無音での自動一時停止")
struct AutoPauseTests {
    let source = FakeAudioSource(chunks: [])
    let clock = FakeClock()
    let notifier = FakeAutoPauseNotifier()

    func makeController(
        engine: ScriptedEngine,
        directory: URL,
        interval: @escaping @MainActor () -> TimeInterval? = { 300 }
    ) -> SessionController {
        SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: SessionRepository(rootDirectory: directory),
            clock: clock,
            autoPauseInterval: interval,
            autoPauseNotifier: notifier
        )
    }

    @Test("新しい文字が設定の時間出なければ一時停止し、案内と通知を出す")
    func pausesAfterSilence() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let controller = makeController(engine: ScriptedEngine(eventsPerStart: [[]]), directory: dir.url)
        await controller.start()

        clock.advance(299)
        await controller.checkSilence()
        #expect(controller.state == .recording)
        #expect(controller.autoPausedAfterSilence == nil)

        clock.advance(1)
        await controller.checkSilence()
        #expect(controller.state == .paused)
        #expect(controller.autoPausedAfterSilence == 300)
        #expect(notifier.notified == [300])

        // 一時停止中は、もう一度確かめても何もしない。
        clock.advance(600)
        await controller.checkSilence()
        #expect(notifier.notified == [300])
        await controller.stop()
    }

    @Test("文字が出たら（未確定でも）数え直す。空の未確定は数えない")
    func speechResetsTimer() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let controller = makeController(engine: engine, directory: dir.url)
        await controller.start()

        clock.advance(200)
        await engine.emit(.volatile("こんにちは"))
        await waitUntil { controller.transcript.volatileText == "こんにちは" }
        clock.advance(200)
        await controller.checkSilence()
        #expect(controller.state == .recording)

        await engine.emit(.final(TranscriptSegment(start: 0, end: 1, text: "こんにちは")))
        await waitUntil { controller.transcript.segments.count == 1 }
        clock.advance(250)
        await engine.emit(.volatile(""))
        await waitUntil { controller.transcript.volatileText.isEmpty }
        await controller.checkSilence()
        #expect(controller.state == .recording)

        clock.advance(50)
        await controller.checkSilence()
        #expect(controller.state == .paused)
        await controller.stop()
    }

    @Test("オフなら、どれだけ無音でも止めない")
    func disabled() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let controller = makeController(engine: ScriptedEngine(eventsPerStart: [[]]), directory: dir.url, interval: { nil })
        await controller.start()
        clock.advance(10_000)
        await controller.checkSilence()
        #expect(controller.state == .recording)
        #expect(notifier.notified.isEmpty)
        await controller.stop()
    }

    @Test("再開すると案内を消し、無音を数え直す。停止でも案内を消す")
    func resumeAndStopClearNotice() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let controller = makeController(engine: ScriptedEngine(eventsPerStart: [[], [], []]), directory: dir.url)
        await controller.start()
        clock.advance(300)
        await controller.checkSilence()
        #expect(controller.state == .paused)

        clock.advance(1000)
        await controller.resume()
        #expect(controller.state == .recording)
        #expect(controller.autoPausedAfterSilence == nil)
        clock.advance(299)
        await controller.checkSilence()
        #expect(controller.state == .recording)

        clock.advance(1)
        await controller.checkSilence()
        #expect(controller.autoPausedAfterSilence == 300)
        await controller.stop()
        #expect(controller.state == .finished)
        #expect(controller.autoPausedAfterSilence == nil)
    }

    @Test("手で一時停止したときは、案内も通知も出さない")
    func manualPauseHasNoNotice() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let controller = makeController(engine: ScriptedEngine(eventsPerStart: [[]]), directory: dir.url)
        await controller.start()
        await controller.pause()
        clock.advance(1000)
        await controller.checkSilence()
        #expect(controller.autoPausedAfterSilence == nil)
        #expect(notifier.notified.isEmpty)
        await controller.stop()
    }

    @Test("案内の分数の表記")
    func minutesText() {
        #expect(SessionController.minutesText(300) == "5 分")
        #expect(SessionController.minutesText(900) == "15 分")
        #expect(SessionController.minutesText(30) == "30 秒")
    }
}

@MainActor
@Suite("自動一時停止の設定")
struct AutoPauseSettingsTests {
    @Test("既定はオン・5分。選べない分数が保存されていたら5分に戻す。オフなら間隔は nil")
    func defaultsAndValidation() throws {
        let suite = "AutoPauseSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.autoPauseOnSilence)
        #expect(settings.autoPauseMinutes == 5)
        #expect(settings.autoPauseInterval == 300)

        settings.autoPauseMinutes = 10
        settings.autoPauseOnSilence = false
        #expect(settings.autoPauseInterval == nil)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.autoPauseMinutes == 10)
        #expect(!reloaded.autoPauseOnSilence)

        defaults.set(7, forKey: "LiveMinutes.autoPauseMinutes")
        #expect(AppSettings(defaults: defaults).autoPauseMinutes == 5)
    }
}
