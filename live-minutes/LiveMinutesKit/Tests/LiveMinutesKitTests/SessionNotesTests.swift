import Foundation
import Testing
@testable import LiveMinutesKit

/// SessionController とライブ更新（NotesEngine）の接続のテスト。
@MainActor
@Suite("SessionController とライブ更新")
struct SessionNotesTests {
    let source = FakeAudioSource(chunks: [])
    let sessionClock = FakeClock()
    let notesClock = ManualNotesClock()
    let client = ControlledLLMClient()

    private func makeController(
        engine: ScriptedEngine,
        root: URL,
        hasAPIKey: Bool = true
    ) -> (SessionController, SessionRepository) {
        let repository = SessionRepository(rootDirectory: root)
        let client = self.client
        let clock = notesClock
        let factory: @MainActor (SessionMeta, NotesStore) async -> NotesEngine? = { meta, store in
            guard hasAPIKey else { return nil }
            return NotesEngine(
                client: client,
                configuration: NotesEngine.Configuration(meetingTitle: meta.title, glossary: []),
                clock: clock,
                systemPrompt: "prompt",
                schema: Data("{}".utf8),
                modelSelection: { NotesEngine.ModelSelection(model: "gpt-6-luna", reasoningEffort: "low") },
                persist: { notes in try? await repository.writeNotes(notes, to: meta.id) },
                report: { store.receive($0) }
            )
        }
        let controller = SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: repository,
            clock: sessionClock,
            notesEngineFactory: factory
        )
        return (controller, repository)
    }

    @Test("API キーがなければライブ更新は動かさず、文字起こしだけを続ける")
    func withoutAPIKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("こんにちは"))]])
        let (controller, _) = makeController(engine: engine, root: dir.url, hasAPIKey: false)

        await controller.start()
        await controller.waitForNotesAttach()
        #expect(controller.notes.status == .notConfigured)
        await controller.stop()
        #expect(controller.state == .finished)
        #expect(controller.transcript.segments.count == 1)
        #expect(await client.requests.isEmpty)
    }

    @Test("確定した発言をライブ更新に渡し、停止時に残りを送ってから finished になる")
    func forwardsSegmentsAndFlushesOnStop() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("決めましょう", at: 3))]])
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        #expect(controller.notes.status == .waiting)
        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        #expect(await client.sentTexts(0) == ["決めましょう"])
        #expect(controller.state == .finishing)

        await client.respond(0, ops: [NotesOp(op: .addTopic, topicID: "new-1", title: "決定")])
        await stopping.value
        #expect(controller.state == .finished)
        #expect(controller.notes.notes.topics.map(\.title) == ["決定"])
        #expect(controller.notes.status == .inactive)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadNotes(id: id).topics.map(\.title) == ["決定"])
    }

    @Test("ノートの送信を待っている間も、meta.json はすでに finished。上限時間を超えたら打ち切る")
    func flushTimeoutAfterMetaWritten() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("最後"))]])
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        let id = try #require(controller.sessionMeta?.id)
        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        #expect(try await repository.loadMeta(id: id).status == .finished)

        await waitUntil { notesClock.sleeperCount >= 1 }
        notesClock.advance(by: SessionController.notesFlushTimeout)
        await stopping.value
        #expect(controller.state == .finished)
    }

    @Test("アプリの終了時はノートの残りを待たない")
    func terminationDoesNotWaitForNotes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("途中"))]])
        let (controller, repository) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        await controller.finishForTermination()
        #expect(controller.state == .finished)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
        #expect(await client.requests.isEmpty)
    }

    @Test("停止がノートの送信を待っている最中に終了しても、すぐに抜ける")
    func terminationDuringFlush() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("最後"))]])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        await controller.finishForTermination()
        await stopping.value
        #expect(controller.state == .finished)
    }

    @Test("一時停止トグルがオンの間に確定した発言は、ライブ更新に渡さない（文字起こしには残る）")
    func pausedSegmentsAreNotForwarded() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        controller.setNotesSendingPaused(true)
        await engine.emit(.final(segment("機微な話", at: 1)))
        await waitUntil { controller.transcript.segments.count == 1 }
        await waitUntil { controller.notes.status == .paused }

        controller.setNotesSendingPaused(false)
        // オフがエンジンに伝わってから次の発言を流す。
        await controller.waitForNotesPauseChange()
        await engine.emit(.final(segment("普通の話", at: 2)))
        await waitUntil { controller.transcript.segments.count == 2 }

        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        #expect(await client.sentTexts(0) == ["普通の話"])
        await client.respond(0, ops: [])
        await stopping.value
    }

    @Test("新しい会議を開始すると、一時停止トグルはオフに戻る")
    func pauseResetsOnNewSession() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine()
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        controller.setNotesSendingPaused(true)
        await controller.stop()
        #expect(controller.notes.isSendingPaused)

        await controller.start()
        await controller.waitForNotesAttach()
        #expect(controller.notes.isSendingPaused == false)
        await controller.finishForTermination()
    }

    @Test("LLM の失敗で、録音と文字起こしは止まらない")
    func llmFailureDoesNotStopRecording() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment(characters: 130))]])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        notesClock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, error: .server(status: 500))
        await waitUntil {
            if case .failed = controller.notes.status { return true }
            return false
        }
        #expect(controller.state == .recording)

        await engine.emit(.final(segment("続きの発言", at: 30)))
        await waitUntil { controller.transcript.segments.count == 2 }
        #expect(controller.state == .recording)
        await controller.finishForTermination()
    }

    @Test("会議中に API キーを保存すると、その時点からライブ更新を始める")
    func startsNotesWhenKeyAdded() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let keyBox = KeyBox()
        let repository = SessionRepository(rootDirectory: dir.url)
        let client = self.client
        let clock = notesClock
        let controller = SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: repository,
            clock: sessionClock,
            notesEngineFactory: { meta, store in
                guard keyBox.hasKey else { return nil }
                return NotesEngine(
                    client: client,
                    configuration: NotesEngine.Configuration(meetingTitle: meta.title, glossary: []),
                    clock: clock,
                    systemPrompt: "prompt",
                    schema: Data("{}".utf8),
                    modelSelection: { NotesEngine.ModelSelection(model: "m", reasoningEffort: nil) },
                    persist: { _ in },
                    report: { store.receive($0) }
                )
            }
        )

        await controller.start()
        await controller.waitForNotesAttach()
        #expect(controller.notes.status == .notConfigured)
        keyBox.hasKey = true
        await controller.credentialsDidChange()
        #expect(controller.notes.status == .waiting)

        await engine.emit(.final(segment("キーを入れた後の発言")))
        await waitUntil { controller.transcript.segments.count == 1 }
        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, ops: [])
        await stopping.value
    }
}

extension SessionNotesTests {
    @Test("止まっているライブ更新は、API キーの保存で再開する。会議が終わった後のキー保存では何も作らない")
    func apiKeyChangeResumesAndIgnoresAfterSession() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment(characters: 130))]])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        notesClock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, error: .authentication)
        await waitUntil {
            if case .failed(_, true, _) = controller.notes.status { return true }
            return false
        }

        await controller.credentialsDidChange()
        await waitUntil { await client.requests.count == 2 }
        await client.respond(1, ops: [])
        await waitUntil { controller.notes.status == .waiting }

        await controller.finishForTermination()
        await controller.credentialsDidChange()
        #expect(controller.notes.status == .inactive)
        #expect(await client.requests.count == 2)
    }
}

@MainActor
final class KeyBox {
    var hasKey = false
}

// MARK: - Phase 4B-2（ChatGPT のプランとの接続）

/// 手で開けるまで待たせる門（エンジン作りがキーチェーンの許可ダイアログで止まっている状態を作る）。
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingCount = 0

    func wait() async {
        guard !isOpen else { return }
        waitingCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

extension SessionNotesTests {
    /// エンジン作りを門で止められるコントローラー
    func makeGatedController(
        engine: ScriptedEngine,
        root: URL,
        gate: Gate,
        isConfigured: @escaping @MainActor () -> Bool = { true }
    ) -> SessionController {
        let repository = SessionRepository(rootDirectory: root)
        let client = self.client
        let clock = notesClock
        return SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: repository,
            clock: sessionClock,
            notesEngineFactory: { meta, store in
                // 「設定済みか」を判断してから、門で止まる（判断の後に資格情報が変わる状況を作れるように）。
                let configured = isConfigured()
                await gate.wait()
                guard configured else { return nil }
                return NotesEngine(
                    client: client,
                    configuration: NotesEngine.Configuration(meetingTitle: meta.title, glossary: []),
                    clock: clock,
                    systemPrompt: "prompt",
                    schema: Data("{}".utf8),
                    modelSelection: { NotesEngine.ModelSelection(model: "m", reasoningEffort: nil) },
                    persist: { _ in },
                    report: { store.receive($0) }
                )
            }
        )
    }

    @Test("エンジン作りが止まっていても（キーチェーンのダイアログなど）、会議は録音中になる。その間の発言はためて、付けたら送る")
    func attachDoesNotBlockStart() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let gate = Gate()
        let controller = makeGatedController(engine: engine, root: dir.url, gate: gate)

        await controller.start()
        #expect(controller.state == .recording)
        #expect(controller.isBusy == false)
        await waitUntil { await gate.waitingCount == 1 }

        await engine.emit(.final(segment("ダイアログの間の発言", at: 1)))
        await waitUntil { controller.transcript.segments.count == 1 }
        await gate.open()
        await controller.waitForNotesAttach()
        #expect(controller.notes.status == .waiting)
        await engine.emit(.final(segment("その後の発言", at: 2)))
        await waitUntil { controller.transcript.segments.count == 2 }

        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        #expect(await client.sentTexts(0) == ["ダイアログの間の発言", "その後の発言"])
        await client.respond(0, ops: [])
        await stopping.value
    }

    @Test("エンジン作りの途中で停止したら、待たずに終わり、後からできたエンジンは使わない")
    func stopWhileAttaching() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("発言"))]])
        let gate = Gate()
        let controller = makeGatedController(engine: engine, root: dir.url, gate: gate)

        await controller.start()
        await waitUntil { await gate.waitingCount == 1 }
        await controller.stop()
        #expect(controller.state == .finished)
        #expect(controller.notes.status == .inactive)

        await gate.open()
        await controller.waitForNotesAttach()
        #expect(controller.notes.status == .inactive)
        #expect(await client.requests.isEmpty)
    }

    @Test("エンジン作りの途中で一時停止トグルをオンにしたら、ためた発言も捨てる")
    func pauseWhileAttachingDiscardsBuffer() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let gate = Gate()
        let controller = makeGatedController(engine: engine, root: dir.url, gate: gate)

        await controller.start()
        await waitUntil { await gate.waitingCount == 1 }
        await engine.emit(.final(segment("機微な話", at: 1)))
        // 保存を終えてためられるまで待つ（確定の時点でトグルがオフだった発言なので、ためられる）。
        await waitUntil { controller.notesBufferCount == 1 }
        controller.setNotesSendingPaused(true)
        #expect(controller.notesBufferCount == 0)
        controller.setNotesSendingPaused(false)
        await gate.open()
        await controller.waitForNotesAttach()
        await engine.emit(.final(segment("普通の話", at: 2)))
        await waitUntil { controller.transcript.segments.count == 2 }

        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        #expect(await client.sentTexts(0) == ["普通の話"])
        await client.respond(0, ops: [])
        await stopping.value
    }

    @Test("エンジン作りの途中で資格情報が変わったら、作れなかった場合にもう一度試す")
    func reattachWhenCredentialsChangeDuringAttach() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[]])
        let gate = Gate()
        let keyBox = KeyBox()
        let controller = makeGatedController(engine: engine, root: dir.url, gate: gate, isConfigured: { keyBox.hasKey })

        await controller.start()
        // 1回目は「未設定」と判断した後、門で止まっている。
        await waitUntil { await gate.waitingCount == 1 }
        // その間にキーが保存された。作っている途中なので、終わったらもう一度試すよう頼むだけで戻る。
        keyBox.hasKey = true
        await controller.credentialsDidChange()
        await gate.open()
        await controller.waitForNotesAttach()
        // 1回目は未設定で作れなかったが、2回目で作れた。
        #expect(controller.notes.status == .waiting)
        await controller.finishForTermination()
    }

    @Test("会議中に ChatGPT からログアウトされると、次の送信で止まり、ログインし直しの案内になる（発言は残る）")
    func signInRequiredHaltsWithAction() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment(characters: 130))]])
        let (controller, _) = makeController(engine: engine, root: dir.url)

        await controller.start()
        await controller.waitForNotesAttach()
        notesClock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, error: .chatGPTSignInRequired)
        await waitUntil {
            if case .failed(_, true, .signIn) = controller.notes.status { return true }
            return false
        }

        // ログインし直したら（資格情報の変更）、自動で送り直す。
        await controller.credentialsDidChange()
        await waitUntil { await client.requests.count == 2 }
        #expect(await client.sentTexts(1).count == 1)
        await client.respond(1, ops: [])
        await controller.finishForTermination()
    }
}

extension SessionNotesTests {
    @Test("前の会議のエンジン作りが終わる前に次の会議を始めても、次の会議のライブ更新は動く")
    func quickRestartWhileAttaching() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[], []])
        let gate = Gate()
        let controller = makeGatedController(engine: engine, root: dir.url, gate: gate)

        await controller.start()
        await waitUntil { await gate.waitingCount == 1 }
        await controller.stop()
        await controller.start()
        await waitUntil { await gate.waitingCount == 2 }
        await gate.open()
        await controller.waitForNotesAttach()
        #expect(controller.notes.status == .waiting)

        await engine.emit(.final(segment("次の会議の発言", at: 1)))
        await waitUntil { controller.transcript.segments.count == 1 }
        let stopping = Task { await controller.stop() }
        await waitUntil { await client.requests.count == 1 }
        #expect(await client.sentTexts(0) == ["次の会議の発言"])
        await client.respond(0, ops: [])
        await stopping.value
    }
}

// MARK: - Phase 5（議事録）

extension SessionNotesTests {
    private func makeMinutesController(engine: ScriptedEngine, root: URL, generator: FakeMinutesGenerator) -> SessionController {
        SessionController(
            engine: engine,
            source: source,
            permission: FixedPermission(granted: true),
            repository: SessionRepository(rootDirectory: root),
            clock: sessionClock,
            minutesGenerator: generator,
            glossary: { ["LiveMinutes"] }
        )
    }

    @Test("停止すると、保存とノートの後に議事録を作り、その間は確定中。終わったら finished で minutes.md がある")
    func stopGeneratesMinutes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("金曜に出しましょう"))]])
        let generator = FakeMinutesGenerator()
        await generator.set(delay: .milliseconds(50))
        let controller = makeMinutesController(engine: engine, root: dir.url, generator: generator)
        let repository = SessionRepository(rootDirectory: dir.url)

        await controller.start()
        await waitUntil { controller.transcript.segments.count == 1 }
        let stopping = Task { await controller.stop() }
        await waitUntil { controller.minutes.isGenerating }
        #expect(controller.state == .finishing)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMeta(id: id).status == .finished)
        await stopping.value

        #expect(controller.state == .finished)
        #expect(controller.minutes.state == .completed)
        #expect(try await repository.loadMinutes(id: id) == controller.minutes.text)
        let input = try #require(await generator.inputs.first)
        #expect(input.contains("金曜に出しましょう"))
        #expect(input.contains("LiveMinutes"))
    }

    @Test("議事録の生成に失敗しても finished になり、作り直せる")
    func minutesFailureStillFinishes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("発言"))]])
        let generator = FakeMinutesGenerator()
        await generator.set(failAfter: 0)
        let controller = makeMinutesController(engine: engine, root: dir.url, generator: generator)

        await controller.start()
        await waitUntil { controller.transcript.segments.count == 1 }
        await controller.stop()
        #expect(controller.state == .finished)
        if case .failed = controller.minutes.state {} else { Issue.record("失敗を表示する") }

        await generator.set(failAfter: .some(nil))
        await controller.regenerateMinutes()
        #expect(controller.minutes.state == .completed)
    }

    @Test("アプリの終了時は議事録を作らない。議事録の生成中に終了しても、すぐに抜けて保存しない")
    func terminationSkipsMinutes() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let engine = ScriptedEngine(eventsPerStart: [[.final(segment("発言"))], [.final(segment("発言2"))]])
        let generator = FakeMinutesGenerator()
        let controller = makeMinutesController(engine: engine, root: dir.url, generator: generator)
        let repository = SessionRepository(rootDirectory: dir.url)

        await controller.start()
        await waitUntil { controller.transcript.segments.count == 1 }
        await controller.finishForTermination()
        #expect(await generator.inputs.isEmpty)

        await generator.set(delay: .seconds(5))
        await controller.start()
        await waitUntil { controller.transcript.segments.count == 1 }
        let stopping = Task { await controller.stop() }
        await waitUntil { controller.minutes.isGenerating }
        await controller.finishForTermination()
        await stopping.value
        #expect(controller.state == .finished)
        let id = try #require(controller.sessionMeta?.id)
        #expect(try await repository.loadMinutes(id: id) == nil)
    }
}
