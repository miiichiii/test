import Foundation
import Testing
@testable import LiveMinutesKit

/// Phase 4B-2: ライブ更新と ChatGPT のプランの接続のテスト。実際の OpenAI には接続しない。
@MainActor
@Suite("ライブ更新と ChatGPT のプラン")
struct ChatGPTNotesTests {
    let clock = ManualNotesClock()
    let client = ControlledLLMClient()
    let store = NotesStore(highlightDuration: .seconds(30))

    private func makeEngine() throws -> NotesEngine {
        let store = self.store
        return NotesEngine(
            client: client,
            configuration: NotesEngine.Configuration(meetingTitle: "会議", glossary: [], minCharacters: 120, maxInterval: 20, minInterval: 8),
            clock: clock,
            systemPrompt: "prompt",
            schema: try LLMResources.notesOpsSchema(),
            modelSelection: { NotesEngine.ModelSelection(model: "m", reasoningEffort: nil) },
            persist: { _ in },
            report: { store.receive($0) }
        )
    }

    @Test("送信中に再試行（接続方法の切り替えなど）があったら、古い資格情報の失敗では止めず、1回だけ送り直す")
    func retryDuringSendDoesNotHalt() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        await waitUntil { await client.requests.count == 1 }

        await engine.retryNow()
        await client.respond(0, error: .authentication)
        await waitUntil { await !engine.isInFlight }
        #expect(await engine.isHalted == false)
        #expect(await engine.pending.count == 1)

        clock.advance(by: 8)
        await waitUntil { await client.requests.count == 2 }
        // 次も直らない失敗なら、今度は止める。
        await client.respond(1, error: .authentication)
        await waitUntil { await engine.isHalted }
    }

    @Test("ストリームの途中の server_error が続いても、発言を捨てずに送り直し続ける")
    func serverErrorsDoNotDropBatch() async throws {
        let engine = try makeEngine()
        await engine.add(segment(characters: 130))
        clock.advance(by: 8)
        for index in 0..<3 {
            await waitUntil { await client.requests.count == index + 1 }
            await client.respond(index, error: .failed(code: "server_error", message: nil))
            await waitUntil { await !engine.isInFlight }
            clock.advance(by: 20)
        }
        await waitUntil { await client.requests.count == 4 }
        #expect(await engine.pending.count == 1)
        #expect(store.hasDroppedSegments == false)
        await engine.abort()
    }

    @Test("一時的とみなすのは server_error と rate_limit_exceeded だけ。insufficient_quota は残高の不足にする")
    func failureCodes() {
        #expect(LLMError.isTransientFailureCode("server_error"))
        #expect(LLMError.isTransientFailureCode("rate_limit_exceeded"))
        #expect(!LLMError.isTransientFailureCode("invalid_prompt"))
        #expect(!LLMError.isTransientFailureCode(nil))
        #expect(LLMError.fromFailure(code: "insufficient_quota", message: nil, param: nil) == .quotaExceeded)
    }

    @Test("案内の操作: 使用量の上限は使用量の確認、ログインの問題はログイン、それ以外は設定の確認")
    func failureActions() {
        #expect(NotesFailureAction(LLMError.usageLimitReached) == .manageUsage)
        #expect(NotesFailureAction(LLMError.chatGPTSignInRequired) == .signIn)
        #expect(NotesFailureAction(LLMError.chatGPTPlanNotGranted) == .signIn)
        #expect(NotesFailureAction(LLMError.planNotEligible(message: nil)) == .checkSettings)
        #expect(NotesFailureAction(LLMError.authentication) == .checkSettings)
        #expect(NotesFailureAction(nil) == .checkSettings)
        #expect(LLMError.planNotEligible(message: nil).localizedDescription.contains("API キーに切り替えられます"))
    }

    @Test("「設定済みか」は接続方法ごとに判断する")
    func isConfiguredPerMethod() async throws {
        let suite = "LiveMinutesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let secrets = InMemorySecretStore(key: "test-key")
        let signedIn = ChatGPTAuth(store: InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: Date().addingTimeInterval(3600))))
        let signedOut = ChatGPTAuth(store: InMemoryChatGPTCredentialStore())

        settings.authMethod = .apiKey
        #expect(await LiveNotesFactory.isConfigured(settings: settings, secretStore: secrets, chatGPT: signedOut))
        #expect(await LiveNotesFactory.isConfigured(settings: settings, secretStore: InMemorySecretStore(), chatGPT: signedIn) == false)

        settings.authMethod = .chatGPTPlan
        #expect(await LiveNotesFactory.isConfigured(settings: settings, secretStore: secrets, chatGPT: signedOut) == false)
        #expect(await LiveNotesFactory.isConfigured(settings: settings, secretStore: InMemorySecretStore(), chatGPT: signedIn))
    }

    @Test("「ChatGPT プランを使います」の案内は、プランの利用が初めて許可されたときに出し、閉じたら二度と出さない")
    func planUsageWelcome() async throws {
        let suite = "LiveMinutesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ChatGPTFixtures.record(expiresAt: Date().addingTimeInterval(3600))

        let first = ChatGPTAccount(
            auth: ChatGPTAuth(store: InMemoryChatGPTCredentialStore(record: record)),
            openURL: { _ in true }, onCredentialsChange: {}, defaults: defaults
        )
        #expect(first.showsPlanUsageWelcome == false)
        await first.load()
        await waitUntil { first.showsPlanUsageWelcome }
        first.acknowledgePlanUsageWelcome()
        #expect(first.showsPlanUsageWelcome == false)

        let second = ChatGPTAccount(
            auth: ChatGPTAuth(store: InMemoryChatGPTCredentialStore(record: record)),
            openURL: { _ in true }, onCredentialsChange: {}, defaults: defaults
        )
        await second.load()
        await waitUntil { second.state != .unknown }
        #expect(second.showsPlanUsageWelcome == false)

        // プランの利用が許可されていなければ出さない。
        let otherSuite = "LiveMinutesTests.\(UUID().uuidString)"
        let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let notGranted = ChatGPTAccount(
            auth: ChatGPTAuth(store: InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(
                expiresAt: Date().addingTimeInterval(3600), scopes: ["openid"]
            ))),
            openURL: { _ in true }, onCredentialsChange: {}, defaults: otherDefaults
        )
        await notGranted.load()
        await waitUntil { notGranted.state != .unknown }
        #expect(notGranted.showsPlanUsageWelcome == false)
    }

    @Test("ChatGPTAccount は、作っただけではキーチェーンを読まない")
    func accountDoesNotLoadOnInit() async throws {
        let suite = "LiveMinutesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: Date().addingTimeInterval(3600)))
        await store.setFailsToLoad(true)
        let account = ChatGPTAccount(auth: ChatGPTAuth(store: store), openURL: { _ in true }, onCredentialsChange: {}, defaults: defaults)
        try await Task.sleep(for: .milliseconds(50))
        #expect(account.state == .unknown)
        await account.load()
        await waitUntil { account.state == .unavailable }
    }

    @Test("会議の開始時に読めなかったログインの情報が、後で読めたら、ライブ更新に知らせる")
    func notifiesWhenCredentialsBecomeReadable() async throws {
        let suite = "LiveMinutesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: Date().addingTimeInterval(3600)))
        await store.setFailsToLoad(true)
        let auth = ChatGPTAuth(store: store)
        let notified = CountBox()
        let account = ChatGPTAccount(auth: auth, openURL: { _ in true }, onCredentialsChange: { notified.count += 1 }, defaults: defaults)

        await account.load()
        await waitUntil { account.state == .unavailable }
        #expect(notified.count == 0)
        await store.setFailsToLoad(false)
        await account.load()
        await waitUntil { notified.count == 1 }
        #expect(account.state == .signedIn(email: "user@example.com", planUsageGranted: true))
    }
}

@MainActor
final class CountBox {
    var count = 0
}
