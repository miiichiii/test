import Foundation
import Synchronization
import Testing
@testable import LiveMinutesKit

/// 実装後のレビューで直した点のテスト（DESIGN.md §4.11）。実際の OpenAI には接続しない。
@Suite("ChatGPT でのログイン（レビューでの修正）")
struct ChatGPTReviewFixTests {
    let clock = TestWallClock()

    private func makeAuth(
        server: ChatGPTStubServer,
        store: InMemoryChatGPTCredentialStore,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> ChatGPTAuth {
        let clock = self.clock
        return ChatGPTAuth(
            session: StubURLProtocol.makeSession(),
            endpoints: server.endpoints,
            store: store,
            hostID: { ChatGPTAuthTests.hostID },
            randomBytes: { count in Data(ChatGPTAuthTests.fixedRandom.prefix(count)) },
            now: { clock.now },
            sleep: sleep,
            preferredPort: nil,
            callbackTimeout: 10
        )
    }

    private var flow: ChatGPTSignInFlowTests { ChatGPTSignInFlowTests(clock: clock) }

    // MARK: - ログインし直しとアカウント

    @Test("要ログインからのログインし直しでは、残した ID トークンを id_token_hint に付ける。ログアウトの後は付けない")
    func idTokenHintAfterTerminalError() async throws {
        let key = try TestRSAKey()
        let server = flow.server(key: key, clientID: ChatGPTFixtures.clientID)
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        // 1回目の更新は終端のエラーにする（トークンの応答の1回目）。
        let refreshFails = ChatGPTStubServer(token: { _ in .json(400, #"{"error":"invalid_grant"}"#) }, jwks: { _ in .json(500, "{}") })
        let failing = makeAuth(server: refreshFails, store: store)
        await #expect(throws: LLMError.chatGPTSignInRequired) { try await failing.accessToken() }

        let auth = makeAuth(server: server, store: store)
        let browser = ChatGPTSignInFlowTests.FakeBrowser { [ChatGPTSignInFlowTests.callback($0, clientID: nil)] }
        _ = try await auth.signIn { await browser.open($0) }
        let opened = try #require(browser.openedQueries.withLock { $0 }.first)
        #expect(opened["client_id"] == ChatGPTFixtures.clientID)
        #expect(opened["id_token_hint"] == "old-id-token")

        _ = await auth.signOut()
        let afterSignOut = ChatGPTSignInFlowTests.FakeBrowser { [ChatGPTSignInFlowTests.callback($0, clientID: nil)] }
        _ = try await auth.signIn { await afterSignOut.open($0) }
        let reopened = try #require(afterSignOut.openedQueries.withLock { $0 }.first)
        #expect(reopened["client_id"] == ChatGPTFixtures.clientID)
        #expect(reopened["id_token_hint"] == nil)
    }

    @Test("別のアカウントでログイン: 保存済みの登録を使わずに新しく登録し、記録ごと置き換える")
    func newAccount() async throws {
        let key = try TestRSAKey()
        let server = flow.server(key: key, clientID: "oaiapp_new", sub: "another-user")
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now).withoutTokens())
        let auth = makeAuth(server: server, store: store)
        let browser = ChatGPTSignInFlowTests.FakeBrowser { [ChatGPTSignInFlowTests.callback($0, clientID: "oaiapp_new")] }

        _ = try await auth.signIn(mode: .newAccount) { await browser.open($0) }
        let opened = try #require(browser.openedQueries.withLock { $0 }.first)
        #expect(opened["client_id"] == "dynamic_agent_client")
        #expect(opened["agent_name_hint"] == "LiveMinutes")
        #expect(opened["id_token_hint"] == nil)
        let saved = try #require(try await store.load())
        #expect(saved.clientID == "oaiapp_new")
        #expect(saved.subject == "another-user")
    }

    @Test("プランの利用の許可し直しでは、同意の画面を出す prompt=consent を付ける")
    func grantPlanUsage() async throws {
        let key = try TestRSAKey()
        let server = flow.server(key: key, clientID: ChatGPTFixtures.clientID)
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(
            expiresAt: clock.now.addingTimeInterval(3000), scopes: ["openid", "email", "profile"]
        ))
        let auth = makeAuth(server: server, store: store)
        let browser = ChatGPTSignInFlowTests.FakeBrowser { [ChatGPTSignInFlowTests.callback($0, clientID: nil)] }

        #expect(try await auth.signIn(mode: .grantPlanUsage) { await browser.open($0) } == .signedIn(email: "user@example.com", planUsageGranted: true))
        let opened = try #require(browser.openedQueries.withLock { $0 }.first)
        #expect(opened["prompt"] == "consent")
        #expect(opened["client_id"] == ChatGPTFixtures.clientID)
    }

    @Test("ログインを重ねて始めたら、前のものはキャンセルされ、後のものが終わる")
    func overlappingSignIn() async throws {
        let key = try TestRSAKey()
        let server = flow.server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let firstOpened = Mutex(false)

        let first = Task { try await auth.signIn { _ in firstOpened.withLock { $0 = true }; return true } }
        await waitUntil { firstOpened.withLock { $0 } }
        let browser = ChatGPTSignInFlowTests.FakeBrowser { [ChatGPTSignInFlowTests.callback($0)] }
        let second = try await auth.signIn { await browser.open($0) }

        #expect(second == .signedIn(email: "user@example.com", planUsageGranted: true))
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await auth.state == .signedIn(email: "user@example.com", planUsageGranted: true))
    }

    // MARK: - ログアウト

    @Test("ログアウトの待ちには上限がある。上限の後に終わった更新の結果は使わず、新しいトークンも取り消す")
    func signOutWaitIsBounded() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON(), delay: 0.3) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        // 待つ上限はすぐに来る。
        let auth = makeAuth(server: server, store: store)

        let refreshing = Task { try await auth.accessToken() }
        await waitUntil { server.tokenRequests.count == 1 }
        _ = await auth.signOut()
        // 待たずに、その時点のリフレッシュトークンを取り消している。
        #expect(ChatGPTFixtures.formFields(try #require(server.revokeRequests.first))["token"] == "refresh-1")

        await #expect(throws: LLMError.chatGPTSignInRequired) { try await refreshing.value }
        // 上限の後に届いた新しいリフレッシュトークンも取り消す。
        #expect(server.revokeRequests.map { ChatGPTFixtures.formFields($0)["token"] } == ["refresh-1", "refresh-2"])
        #expect(try await store.load()?.hasTokens == false)
        #expect(await auth.state == .signedOut)
    }

    @Test("キーチェーンを読めないときのログアウトは、取り消しを確かめられなかったと返す")
    func signOutWhenUnavailable() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(500, "{}") }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(3000)))
        await store.setFailsToLoad(true)
        let auth = makeAuth(server: server, store: store)

        #expect(await auth.signOut().revocationConfirmed == false)
        #expect(await auth.state == .unavailable)
        #expect(server.revokeRequests.isEmpty)
    }

    // MARK: - 更新

    @Test("保存に失敗している間は、キーチェーンの古い記録を別のプロセスの更新と取り違えない")
    func doesNotAdoptStaleKeychainRecord() async throws {
        let server = ChatGPTStubServer(
            token: { attempt in .json(200, ChatGPTFixtures.tokenJSON(accessToken: "access-\(attempt + 2)", refreshToken: "refresh-\(attempt + 2)")) },
            jwks: { _ in .json(500, "{}") }
        )
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)
        _ = await auth.loadState()
        await store.setFailsToSave(true)
        #expect(try await auth.accessToken() == "access-2")

        // 保存できないまま期限が来た。キーチェーンには古い refresh-1 が残っている。
        clock.advance(by: 3500)
        #expect(try await auth.accessToken() == "access-3")
        #expect(server.tokenRequests.map { ChatGPTFixtures.formFields($0)["refresh_token"] } == ["refresh-1", "refresh-2"])
    }

    @Test("earliest_refresh_at より前は、期限まで30秒を切るまで更新しない")
    func earliestRefreshAt() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON()) }, jwks: { _ in .json(500, "{}") })
        var record = ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(200))
        record.earliestRefreshAt = clock.now.addingTimeInterval(100)
        let store = InMemoryChatGPTCredentialStore(record: record)
        let auth = makeAuth(server: server, store: store)

        // 期限まで5分を切っているが、earliest_refresh_at の前。
        #expect(try await auth.accessToken() == "access-1")
        #expect(server.tokenRequests.isEmpty)
        clock.advance(by: 100)
        #expect(try await auth.accessToken() == "access-2")
        #expect(server.tokenRequests.count == 1)
    }

    @Test("earliest_refresh_at の前でも、期限まで30秒を切ったら更新する")
    func earliestRefreshAtFloor() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON()) }, jwks: { _ in .json(500, "{}") })
        var record = ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(20))
        record.earliestRefreshAt = clock.now.addingTimeInterval(100)
        let auth = makeAuth(server: server, store: InMemoryChatGPTCredentialStore(record: record))
        #expect(try await auth.accessToken() == "access-2")
    }

    @Test("earliest_refresh_at は Unix 秒（数値・数字の文字列）と ISO 8601 を読み、読めなければ無視する")
    func flexibleDate() {
        #expect(ChatGPTAuth.flexibleDate(NSNumber(value: 1_800_000_000)) == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ChatGPTAuth.flexibleDate("1800000000") == Date(timeIntervalSince1970: 1_800_000_000))
        // 2027-01-15T08:00:00Z は Unix 秒で 1_800_000_000
        #expect(ChatGPTAuth.flexibleDate("2027-01-15T08:00:00Z") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ChatGPTAuth.flexibleDate("soon") == nil)
        #expect(ChatGPTAuth.flexibleDate(nil) == nil)
    }

    @Test("トークンのエンドポイントの 429 は、設定の誤りではなくレート制限として扱う")
    func refreshRateLimited() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(429, "{}") }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)
        await #expect(throws: LLMError.rateLimited) { try await auth.accessToken() }
        #expect(try await store.load()?.refreshToken == "refresh-1")
    }

    @Test("コールバックの error は、英数字と _ だけ、64文字までにして扱う")
    func sanitizedCode() {
        #expect(ChatGPTAuth.sanitizedCode("server_error") == "server_error")
        #expect(ChatGPTAuth.sanitizedCode("<script>x") == "scriptx")
        #expect(ChatGPTAuth.sanitizedCode(String(repeating: "a", count: 100)).count == 64)
        #expect(ChatGPTAuth.sanitizedCode("日本語") == "unknown")
    }
}

// MARK: - クライアント

@Suite("OpenAIResponsesClient（ChatGPT のプラン・レビューでの修正）")
struct ChatGPTClientReviewFixTests {
    private func makeClient(
        credentials: any CredentialProvider,
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (OpenAIResponsesClient, URL) {
        let url = StubURLProtocol.register(handler)
        return (OpenAIResponsesClient(session: StubURLProtocol.makeSession(), endpoint: url, credentials: credentials, sleep: { _ in }), url)
    }

    private func collect(_ stream: AsyncThrowingStream<String, any Error>) async throws -> String {
        var text = ""
        for try await delta in stream { text += delta }
        return text
    }

    private let textRequest = TextStreamRequest(model: "gpt-6.1-sol", instructions: "i", input: "in", reasoningEffort: "medium")

    @Test("ストリーミング: ChatGPT のときも配列の input と Bearer のトークンで送り、401 は差分の前なら1回だけ送り直す")
    func streamTextWithChatGPT() async throws {
        let credentials = ChatGPTClientTests.FakeCredentials(.chatGPTPlan(accessToken: "old"), nextAfterUnauthorized: .chatGPTPlan(accessToken: "new"))
        let (client, url) = makeClient(credentials: credentials) { attempt in
            attempt == 0
                ? .json(401, "{}")
                : .http(status: 200, chunks: [ChatGPTClientTests.sse([ChatGPTClientTests.delta("こんにちは"), ChatGPTClientTests.completed])])
        }
        #expect(try await collect(client.streamText(textRequest)) == "こんにちは")
        let sent = StubURLProtocol.requests(for: url)
        #expect(sent.map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new"])
        let body = try #require(sent.last).bodyJSON
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect((body["input"] as? [[String: Any]])?.first?["content"] as? String == "in")
    }

    @Test("ストリーミング: 差分を渡した後に届いた失敗では、送り直さない（文が重複するため）")
    func streamTextDoesNotRecoverAfterOutput() async throws {
        let credentials = ChatGPTClientTests.FakeCredentials(.chatGPTPlan(accessToken: "old"), nextAfterUnauthorized: .chatGPTPlan(accessToken: "new"))
        let failed = #"{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_invalid_user","message":"m"}}}"#
        let (client, url) = makeClient(credentials: credentials) { _ in
            .http(status: 200, chunks: [ChatGPTClientTests.sse([ChatGPTClientTests.delta("途中まで"), failed])])
        }
        var received = ""
        await #expect(throws: LLMError.chatGPTUnauthorized) {
            for try await delta in client.streamText(textRequest) { received += delta }
        }
        #expect(received == "途中まで")
        #expect(StubURLProtocol.requests(for: url).count == 1)
        #expect(await credentials.unauthorizedCalls.isEmpty)
    }

    @Test("ストリームの途中の error イベントでも、ChatGPT のコードを対応付ける")
    func errorEvent() async throws {
        let credentials = ChatGPTClientTests.FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let event = #"{"type":"error","code":"subscription_sharing_usage_limit_exceeded","message":"m"}"#
        let (client, _) = makeClient(credentials: credentials) { _ in .http(status: 200, chunks: [ChatGPTClientTests.sse([event])]) }
        await #expect(throws: LLMError.usageLimitReached) { try await collect(client.streamText(textRequest)) }
    }

    @Test("残りのコード: chatpass_v2_invalid_authorization_context、コードのない 503（再試行する）、API キーでの detail")
    func remainingCodes() async throws {
        let chatGPT = ChatGPTClientTests.FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let request = StructuredOutputRequest(model: "m", instructions: "i", input: "{}", schemaName: "s", schema: Data("{}".utf8), timeout: .seconds(5))

        let (rejected, _) = makeClient(credentials: chatGPT) { _ in ChatGPTClientTests.error(403, code: "chatpass_v2_invalid_authorization_context") }
        await #expect(throws: LLMError.chatGPTRejected(code: "chatpass_v2_invalid_authorization_context")) { try await rejected.structuredOutput(request) }

        let (unavailable, unavailableURL) = makeClient(credentials: chatGPT) { _ in .json(503, #"{"detail":"direct routing unavailable"}"#) }
        await #expect(throws: LLMError.server(status: 503)) { try await unavailable.structuredOutput(request) }
        #expect(StubURLProtocol.requests(for: unavailableURL).count == 3)

        let apiKey = ChatGPTClientTests.FakeCredentials(.apiKey("key"))
        let (detail, _) = makeClient(credentials: apiKey) { _ in .json(403, #"{"detail":"blocked"}"#) }
        await #expect(throws: LLMError.permissionDenied(message: "blocked")) { try await detail.structuredOutput(request) }
    }

    @Test("reasoning を外すのは、使えないと言われたモデルだけ")
    func reasoningFallbackIsPerModel() async throws {
        let credentials = ChatGPTClientTests.FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let ops = OpenAIClientTests.opsJSON
        let (client, url) = makeClient(credentials: credentials) { attempt in
            attempt == 0
                ? ChatGPTClientTests.error(400, code: "subscription_sharing_unsupported_capability", param: "reasoning")
                : .http(status: 200, chunks: [ChatGPTClientTests.sse([ChatGPTClientTests.delta(ops), ChatGPTClientTests.completed])])
        }
        let schema = try LLMResources.notesOpsSchema()
        let luna = StructuredOutputRequest(model: "luna", instructions: "i", input: "{}", schemaName: "notes_ops", schema: schema, reasoningEffort: "low")
        let sol = StructuredOutputRequest(model: "sol", instructions: "i", input: "{}", schemaName: "notes_ops", schema: schema, reasoningEffort: "medium")
        _ = try await client.structuredOutput(luna)
        _ = try await client.structuredOutput(sol)
        let bodies = StubURLProtocol.requests(for: url).map(\.bodyJSON)
        #expect(bodies.count == 3)
        #expect(bodies[1]["reasoning"] == nil)
        #expect(bodies[2]["model"] as? String == "sol")
        #expect(bodies[2]["reasoning"] != nil)
    }
}
