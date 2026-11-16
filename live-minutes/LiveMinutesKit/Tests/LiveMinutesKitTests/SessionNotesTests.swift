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
        controller.setNotesSendingPaused(true)
        await controller.stop()
        #expect(controller.notes.isSendingPaused)

        await controller.start()
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
        notesClock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }
        await client.respond(0, error: .authentication)
        await waitUntil {
            if case .failed(_, true) = controller.notes.status { return true }
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
