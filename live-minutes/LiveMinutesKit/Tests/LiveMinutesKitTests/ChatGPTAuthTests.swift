import Foundation
import Synchronization
import Testing
@testable import LiveMinutesKit

/// ChatGPT でのログインとトークンの管理のテスト（DESIGN.md §4.11）。
/// 認証サーバーは URLProtocol のスタブで、ログインのコールバックは実際の `127.0.0.1` の待ち受けで受ける。
/// 実際の OpenAI（auth.openai.com、api.openai.com）には接続しない。
@Suite("ChatGPT でのログイン")
struct ChatGPTAuthTests {
    static let hostID = "urn:uuid:00000000-0000-0000-0000-000000000001"
    /// 乱数を決まった値にする（state・nonce・検証子がすべてこの値になる）
    static let fixedRandom = Data(repeating: 7, count: 32)
    static var fixedValue: String { OAuthEncoding.base64URL(fixedRandom) }

    let clock = TestWallClock()

    private func makeAuth(
        server: ChatGPTStubServer,
        store: InMemoryChatGPTCredentialStore,
        callbackTimeout: TimeInterval = 10,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> ChatGPTAuth {
        let clock = self.clock
        return ChatGPTAuth(
            session: StubURLProtocol.makeSession(),
            endpoints: server.endpoints,
            store: store,
            hostID: { Self.hostID },
            randomBytes: { count in Data(Self.fixedRandom.prefix(count)) },
            now: { clock.now },
            sleep: sleep,
            preferredPort: nil,
            callbackTimeout: callbackTimeout
        )
    }

    /// 認可 URL のクエリを読む
    static func query(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (url.query(percentEncoded: true) ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding
        }
        return result
    }

    // MARK: - エンコード

    @Test("form と URL のエンコードは、予約されていない文字だけを残す（+ & = / も %XX にする）")
    func percentEncoding() {
        #expect(OAuthEncoding.percentEncode("a+b&c=d/e f~g.h_i-j") == "a%2Bb%26c%3Dd%2Fe%20f~g.h_i-j")
        #expect(OAuthEncoding.percentEncode("日本") == "%E6%97%A5%E6%9C%AC")
        #expect(OAuthEncoding.formBody([("k", "v+1"), ("x", "&")]) == "k=v%2B1&x=%26")
    }

    @Test("PKCE の code_challenge は RFC 7636 の例と一致する")
    func pkceChallenge() {
        #expect(OAuthEncoding.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("認可 URL: 初回は dynamic_agent_client と agent_name_hint、2回目以降は発行された ID と id_token_hint。login_hint は送らない")
    func authorizeURL() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(500, "{}") }, jwks: { _ in .json(500, "{}") })
        let auth = makeAuth(server: server, store: InMemoryChatGPTCredentialStore())

        let first = try #require(await auth.authorizeURL(
            clientID: nil, idTokenHint: nil, redirectURI: "http://127.0.0.1:1455/auth/callback",
            state: "s+1", nonce: "n", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        ))
        let firstQuery = Self.query(first)
        #expect(firstQuery["client_id"] == "dynamic_agent_client")
        #expect(firstQuery["agent_name_hint"] == "LiveMinutes")
        #expect(firstQuery["ext_agent_host_id"] == Self.hostID)
        #expect(firstQuery["id_token_hint"] == nil)
        #expect(firstQuery["login_hint"] == nil)
        #expect(firstQuery["response_type"] == "code")
        #expect(firstQuery["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(firstQuery["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(firstQuery["resource"] == "https://api.openai.com/v1")
        #expect(firstQuery["state"] == "s+1")
        #expect(firstQuery["code_challenge_method"] == "S256")
        #expect(firstQuery["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        // + がそのまま入ると空白と読まれるので、%2B になっていること。
        #expect(first.absoluteString.contains("state=s%2B1"))

        let again = try #require(await auth.authorizeURL(
            clientID: "oaiapp_x", idTokenHint: "hint", redirectURI: "http://127.0.0.1:5000/auth/callback",
            state: "s", nonce: "n", verifier: "v"
        ))
        let againQuery = Self.query(again)
        #expect(againQuery["client_id"] == "oaiapp_x")
        #expect(againQuery["agent_name_hint"] == nil)
        #expect(againQuery["id_token_hint"] == "hint")
    }

    // MARK: - ID トークン

    private func payload(nonce: String = "nonce-1", aud: Any = ChatGPTFixtures.clientID, exp: TimeInterval? = nil,
                         iss: String = ChatGPTStubServer.issuer, sub: String = ChatGPTFixtures.subject) -> [String: Any] {
        ["iss": iss, "aud": aud, "exp": exp ?? clock.now.timeIntervalSince1970 + 3600, "nonce": nonce,
         "sub": sub, "email": "user@example.com"]
    }

    private func verify(_ token: String, keys: [TestRSAKey], nonce: String = "nonce-1") throws -> IDTokenClaims {
        let parts = try IDTokenVerifier.split(token)
        let publicKeys = try IDTokenVerifier.publicKeys(from: Data(TestRSAKey.jwksJSON(keys).utf8))
        guard let kid = parts.header.kid, let key = publicKeys[kid] else { throw IDTokenError.unknownKey }
        try IDTokenVerifier.verifySignature(parts, key: key)
        return try IDTokenVerifier.verifyClaims(parts.payload, issuer: ChatGPTStubServer.issuer, clientID: ChatGPTFixtures.clientID,
                                                nonce: nonce, now: clock.now)
    }

    @Test("ID トークン: 正しい署名とクレームを受け付ける（aud は文字列でも配列でも）")
    func idTokenValid() throws {
        let key = try TestRSAKey()
        #expect(try verify(key.sign(payload: payload()), keys: [key]) == IDTokenClaims(subject: ChatGPTFixtures.subject, email: "user@example.com"))
        #expect(try verify(key.sign(payload: payload(aud: ["other", ChatGPTFixtures.clientID])), keys: [key]).subject == ChatGPTFixtures.subject)
    }

    @Test("ID トークン: 署名の不正、alg の偽り（none・HS256）を拒否する")
    func idTokenSignature() throws {
        let key = try TestRSAKey()
        let attacker = try TestRSAKey(kid: key.kid)
        #expect(throws: IDTokenError.invalidSignature) { try verify(attacker.sign(payload: payload()), keys: [key]) }
        #expect(throws: IDTokenError.unsupportedAlgorithm) { try verify(key.sign(payload: payload(), alg: "none"), keys: [key]) }
        #expect(throws: IDTokenError.unsupportedAlgorithm) { try verify(key.sign(payload: payload(), alg: "HS256"), keys: [key]) }
        #expect(throws: IDTokenError.malformed) { try verify("not-a-jwt", keys: [key]) }
    }

    @Test("ID トークン: iss・aud・exp（60秒の許容）・nonce のそれぞれの不正を拒否する")
    func idTokenClaims() throws {
        let key = try TestRSAKey()
        let now = clock.now.timeIntervalSince1970
        #expect(throws: IDTokenError.issuerMismatch) { try verify(key.sign(payload: payload(iss: "https://evil.example")), keys: [key]) }
        #expect(throws: IDTokenError.audienceMismatch) { try verify(key.sign(payload: payload(aud: "oaiapp_other")), keys: [key]) }
        #expect(throws: IDTokenError.nonceMismatch) { try verify(key.sign(payload: payload(nonce: "other")), keys: [key]) }
        #expect(throws: IDTokenError.missingSubject) { try verify(key.sign(payload: payload(sub: "")), keys: [key]) }
        // 期限を30秒過ぎていても許容の内、90秒過ぎたら拒否。
        #expect(try verify(key.sign(payload: payload(exp: now - 30)), keys: [key]).subject == ChatGPTFixtures.subject)
        #expect(throws: IDTokenError.expired) { try verify(key.sign(payload: payload(exp: now - 90)), keys: [key]) }
    }

    @Test("DER の整数は、最上位ビットが立っていれば 0x00 を前に付け、長い長さも符号化する")
    func derEncoding() {
        #expect(DER.unsignedInteger(Data([0x80])) == Data([0x02, 0x02, 0x00, 0x80]))
        #expect(DER.unsignedInteger(Data([0x00, 0x01])) == Data([0x02, 0x01, 0x01]))
        #expect(DER.length(300) == Data([0x82, 0x01, 0x2C]))
    }

    // MARK: - トークンの更新

    @Test("期限まで5分以上あれば更新しない。5分を切ったら更新し、置き換わったトークンを保存する")
    func refreshNearExpiry() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON()) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(600)))
        let auth = makeAuth(server: server, store: store)

        #expect(try await auth.accessToken() == "access-1")
        #expect(server.tokenRequests.isEmpty)

        clock.advance(by: 360)
        #expect(try await auth.accessToken() == "access-2")
        let fields = ChatGPTFixtures.formFields(try #require(server.tokenRequests.first))
        #expect(fields == [
            "grant_type": "refresh_token", "client_id": ChatGPTFixtures.clientID,
            "refresh_token": "refresh-1", "resource": "https://api.openai.com/v1",
        ])
        let saved = try #require(try await store.load())
        #expect(saved.accessToken == "access-2")
        #expect(saved.refreshToken == "refresh-2")
        #expect(saved.accessTokenExpiresAt == clock.now.addingTimeInterval(3600))
    }

    @Test("同時に期限切れを見つけても、更新は1本にまとめる")
    func refreshIsSingleFlight() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON(), delay: 0.2) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await auth.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "access-2", count: 5))
        #expect(server.tokenRequests.count == 1)
    }

    @Test("待つ側がキャンセルされても、更新は最後まで走って保存される")
    func refreshSurvivesCancellation() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON(), delay: 0.2) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)

        let waiter = Task { try await auth.accessToken() }
        await waitUntil { server.tokenRequests.count == 1 }
        waiter.cancel()
        _ = try? await waiter.value
        await waitUntil { (try? await store.load())?.refreshToken == "refresh-2" }
        #expect(try await store.load()?.refreshToken == "refresh-2")
    }

    @Test("更新したトークンを保存できなくても、メモリで使い続け、次の機会に保存し直す")
    func refreshSaveFailure() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON()) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)
        _ = await auth.loadState()
        await store.setFailsToSave(true)

        #expect(try await auth.accessToken() == "access-2")
        #expect(try await store.load()?.refreshToken == "refresh-1")

        await store.setFailsToSave(false)
        #expect(try await auth.accessToken() == "access-2")
        #expect(try await store.load()?.refreshToken == "refresh-2")
        #expect(server.tokenRequests.count == 1)
    }

    @Test("更新が終端のエラーなら、トークンを捨てて要ログインにする（client_id と sub は残す）", arguments: [
        "invalid_grant", "refresh_token_reused", "refresh_token_expired",
    ])
    func refreshTerminalError(code: String) async throws {
        let server = ChatGPTStubServer(token: { _ in .json(400, #"{"error":"\#(code)"}"#) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)

        await #expect(throws: LLMError.chatGPTSignInRequired) { try await auth.accessToken() }
        let saved = try #require(try await store.load())
        #expect(saved.hasTokens == false)
        // ID トークンは残す（ログインし直すときの id_token_hint に使う）。
        #expect(saved.idToken == "old-id-token")
        #expect(saved.reauthenticationRequired)
        #expect(saved.clientID == ChatGPTFixtures.clientID)
        #expect(saved.subject == ChatGPTFixtures.subject)
        #expect(await auth.state == .needsSignIn(email: "user@example.com"))
    }

    @Test("通信エラー・5xx・invalid_client では、トークンを捨てない", arguments: [
        (StubURLProtocol.Stub.error(.notConnectedToInternet), LLMError.network),
        (StubURLProtocol.Stub.json(503, "{}"), LLMError.server(status: 503)),
        (StubURLProtocol.Stub.json(401, #"{"error":"invalid_client"}"#), LLMError.chatGPTRejected(code: "invalid_client")),
    ])
    func refreshKeepsTokens(stub: StubURLProtocol.Stub, expected: LLMError) async throws {
        let server = ChatGPTStubServer(token: { _ in stub }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)

        await #expect(throws: expected) { try await auth.accessToken() }
        #expect(try await store.load()?.refreshToken == "refresh-1")
        #expect(await auth.state == .signedIn(email: "user@example.com", planUsageGranted: true))
    }

    @Test("別のプロセスがキーチェーンのトークンを更新していたら、更新せずにそれを使う")
    func adoptsTokensFromOtherProcess() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(400, #"{"error":"refresh_token_reused"}"#) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        let auth = makeAuth(server: server, store: store)
        _ = await auth.loadState()
        await store.replace(with: ChatGPTFixtures.record(
            accessToken: "access-other", refreshToken: "refresh-other", expiresAt: clock.now.addingTimeInterval(3000)
        ))

        #expect(try await auth.accessToken() == "access-other")
        #expect(server.tokenRequests.isEmpty)
    }

    @Test("キーチェーンを読めない場合は、要ログインと区別し、上書きも削除もしない")
    func credentialUnavailable() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(500, "{}") }, jwks: { _ in .json(500, "{}") })
        let original = ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(3000))
        let store = InMemoryChatGPTCredentialStore(record: original)
        await store.setFailsToLoad(true)
        let auth = makeAuth(server: server, store: store)

        #expect(await auth.loadState() == .unavailable)
        await #expect(throws: LLMError.chatGPTCredentialUnavailable) { try await auth.accessToken() }
        await store.setFailsToLoad(false)
        #expect(try await store.load() == original)
        #expect(await store.saveCount == 0)
        // 読めるようになったら使える。
        #expect(try await auth.accessToken() == "access-1")
    }

    @Test("プランの利用が許可されていなければ、トークンを使わない")
    func planNotGranted() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(500, "{}") }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(
            expiresAt: clock.now.addingTimeInterval(3000), scopes: ["openid", "email", "profile"]
        ))
        let auth = makeAuth(server: server, store: store)
        await #expect(throws: LLMError.chatGPTPlanNotGranted) { try await auth.accessToken() }
        #expect(await auth.isReadyForPlanUsage() == false)
    }

    @Test("401: 今のトークンがすでに別のものなら更新せずに true、同じなら更新して true")
    func handleUnauthorized() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON()) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(3000)))
        let auth = makeAuth(server: server, store: store)

        #expect(await auth.handleUnauthorized(.chatGPTPlan(accessToken: "stale")) == true)
        #expect(server.tokenRequests.isEmpty)
        #expect(await auth.handleUnauthorized(.chatGPTPlan(accessToken: "access-1")) == true)
        #expect(server.tokenRequests.count == 1)
        #expect(try await auth.accessToken() == "access-2")
        #expect(await auth.handleUnauthorized(.apiKey("key")) == false)
    }

    // MARK: - ログアウト

    @Test("ログアウト: リフレッシュトークンを取り消し、トークンを消す（client_id と sub は残す）")
    func signOut() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(500, "{}") }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(3000)))
        let auth = makeAuth(server: server, store: store)

        #expect(await auth.signOut() == ChatGPTAuth.SignOutResult(revocationConfirmed: true))
        #expect(ChatGPTFixtures.formFields(try #require(server.revokeRequests.first)) == [
            "token": "refresh-1", "token_type_hint": "refresh_token", "client_id": ChatGPTFixtures.clientID,
        ])
        let saved = try #require(try await store.load())
        #expect(saved.hasTokens == false)
        #expect(saved.idToken == nil)
        #expect(saved.clientID == ChatGPTFixtures.clientID)
        #expect(saved.reauthenticationRequired == false)
        #expect(await auth.state == .signedOut)
        await #expect(throws: LLMError.chatGPTSignInRequired) { try await auth.accessToken() }
    }

    @Test("ログアウトの取り消し: 5xx は送り直す。確かめられなくてもトークンは消す", arguments: [
        ([503, 503, 200], true, 3),
        ([400], false, 1),
        ([503, 503, 503], false, 3),
    ])
    func signOutRevocationRetries(statuses: [Int], confirmed: Bool, requestCount: Int) async throws {
        let server = ChatGPTStubServer(
            token: { _ in .json(500, "{}") },
            revoke: { attempt in .http(status: statuses[min(attempt, statuses.count - 1)], chunks: []) },
            jwks: { _ in .json(500, "{}") }
        )
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(3000)))
        let auth = makeAuth(server: server, store: store)

        #expect(await auth.signOut().revocationConfirmed == confirmed)
        #expect(server.revokeRequests.count == requestCount)
        #expect(try await store.load()?.hasTokens == false)
    }

    @Test("更新の途中でログアウトしたら、更新を待ってから最新のリフレッシュトークンを取り消す")
    func signOutDuringRefresh() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(200, ChatGPTFixtures.tokenJSON(), delay: 0.2) }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(-10)))
        // 待つ上限は更新より長い。
        let auth = makeAuth(server: server, store: store, sleep: { try await Task.sleep(for: $0) })

        let refreshing = Task { try? await auth.accessToken() }
        await waitUntil { server.tokenRequests.count == 1 }
        _ = await auth.signOut()
        _ = await refreshing.value

        #expect(ChatGPTFixtures.formFields(try #require(server.revokeRequests.first))["token"] == "refresh-2")
        #expect(try await store.load()?.hasTokens == false)
    }

    @Test("書き換えられなければ、トークンを残さないよう項目ごと消す")
    func signOutDeletesWhenSaveFails() async throws {
        let server = ChatGPTStubServer(token: { _ in .json(500, "{}") }, jwks: { _ in .json(500, "{}") })
        let store = InMemoryChatGPTCredentialStore(record: ChatGPTFixtures.record(expiresAt: clock.now.addingTimeInterval(3000)))
        let auth = makeAuth(server: server, store: store)
        _ = await auth.loadState()
        await store.setFailsToSave(true)

        _ = await auth.signOut()
        #expect(try await store.load() == nil)
    }
}

// MARK: - ログインの流れ（実際の 127.0.0.1 の待ち受けを使う）

@Suite("ChatGPT でのログイン（ブラウザからのコールバック）")
struct ChatGPTSignInFlowTests {
    var clock = TestWallClock()

    /// ブラウザの代わりに、コールバックの URL へ要求を送る。
    /// - Parameter callback: 認可 URL のクエリから、送るコールバックのクエリを作る（nil なら何も送らない）
    final class FakeBrowser: Sendable {
        let finalURLs = Mutex<[URL]>([])
        let statuses = Mutex<[Int]>([])
        /// 開いた認可の URL のクエリ
        let openedQueries = Mutex<[[String: String]]>([])
        private let callbacks: @Sendable ([String: String]) -> [[String: String]]

        init(_ callbacks: @escaping @Sendable ([String: String]) -> [[String: String]]) {
            self.callbacks = callbacks
        }

        func open(_ url: URL) async -> Bool {
            let query = ChatGPTAuthTests.query(url)
            openedQueries.withLock { $0.append(query) }
            guard let redirect = query["redirect_uri"], let base = URL(string: redirect) else { return false }
            let session = URLSession(configuration: .ephemeral)
            for parameters in callbacks(query) {
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
                components?.queryItems = parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let target = components?.url else { continue }
                // 実際のブラウザと同じく、302 をたどって完了のページまで読む。
                if let (_, response) = try? await session.data(from: target), let http = response as? HTTPURLResponse {
                    statuses.withLock { $0.append(http.statusCode) }
                    if let final = http.url { finalURLs.withLock { $0.append(final) } }
                }
            }
            return true
        }
    }

    func makeAuth(server: ChatGPTStubServer, store: InMemoryChatGPTCredentialStore, callbackTimeout: TimeInterval = 10) -> ChatGPTAuth {
        let clock = self.clock
        return ChatGPTAuth(
            session: StubURLProtocol.makeSession(),
            endpoints: server.endpoints,
            store: store,
            hostID: { ChatGPTAuthTests.hostID },
            randomBytes: { count in Data(ChatGPTAuthTests.fixedRandom.prefix(count)) },
            now: { clock.now },
            sleep: { _ in },
            preferredPort: nil,
            callbackTimeout: callbackTimeout
        )
    }

    func idToken(key: TestRSAKey, clientID: String = "oaiapp_new", sub: String = ChatGPTFixtures.subject) -> String {
        key.sign(payload: [
            "iss": ChatGPTStubServer.issuer, "aud": clientID, "exp": clock.now.timeIntervalSince1970 + 3600,
            "nonce": ChatGPTAuthTests.fixedValue, "sub": sub, "email": "user@example.com",
        ])
    }

    func server(key: TestRSAKey, clientID: String = "oaiapp_new", sub: String = ChatGPTFixtures.subject,
                        scope: String? = ChatGPTFixtures.fullScope) -> ChatGPTStubServer {
        let token = idToken(key: key, clientID: clientID, sub: sub)
        let jwks = TestRSAKey.jwksJSON([key])
        return ChatGPTStubServer(
            token: { _ in .json(200, ChatGPTFixtures.tokenJSON(accessToken: "access-new", refreshToken: "refresh-new", idToken: token, scope: scope)) },
            jwks: { _ in .json(200, jwks) }
        )
    }

    static func callback(_ query: [String: String], code: String = "auth-code+1", clientID: String? = "oaiapp_new") -> [String: String] {
        var result = ["code": code, "state": query["state"] ?? ""]
        if let clientID { result["client_id"] = clientID }
        return result
    }

    @Test("初回のログイン: コードを交換し、ID トークンを検証して保存する。ブラウザは完了のページへ移る")
    func firstSignIn() async throws {
        let key = try TestRSAKey()
        let server = server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0)] }

        let state = try await auth.signIn { await browser.open($0) }
        #expect(state == .signedIn(email: "user@example.com", planUsageGranted: true))

        let fields = ChatGPTFixtures.formFields(try #require(server.tokenRequests.first))
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["client_id"] == "oaiapp_new")
        #expect(fields["code"] == "auth-code+1")
        #expect(fields["code_verifier"] == ChatGPTAuthTests.fixedValue)
        #expect(fields["resource"] == "https://api.openai.com/v1")
        #expect(fields["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(fields["redirect_uri"]?.hasSuffix("/auth/callback") == true)

        let saved = try #require(try await store.load())
        #expect(saved.clientID == "oaiapp_new")
        #expect(saved.subject == ChatGPTFixtures.subject)
        #expect(saved.accessToken == "access-new")
        #expect(saved.refreshToken == "refresh-new")
        #expect(saved.idToken != nil)
        #expect(try await auth.accessToken() == "access-new")

        #expect(browser.statuses.withLock { $0 } == [200])
        #expect(browser.finalURLs.withLock { $0 }.first?.path() == "/auth/done")
        // 完了のページの URL にコードが残らない。
        #expect(browser.finalURLs.withLock { $0 }.first?.query() == nil)
    }

    @Test("state が合わない要求には 400 を返して待ち続け、正しいコールバックで終わる")
    func stateMismatchKeepsWaiting() async throws {
        let key = try TestRSAKey()
        let server = server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { query in
            [["code": "evil", "state": "wrong", "client_id": "oaiapp_evil"], Self.callback(query)]
        }

        _ = try await auth.signIn { await browser.open($0) }
        #expect(browser.statuses.withLock { $0 } == [400, 200])
        #expect(ChatGPTFixtures.formFields(try #require(server.tokenRequests.first))["code"] == "auth-code+1")
    }

    @Test("ブラウザで拒否されたら、交換せず何も保存しない")
    func accessDenied() async throws {
        let key = try TestRSAKey()
        let server = server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { query in [["error": "access_denied", "state": query["state"] ?? ""]] }

        await #expect(throws: ChatGPTSignInError.accessDenied) { try await auth.signIn { await browser.open($0) } }
        #expect(server.tokenRequests.isEmpty)
        #expect(try await store.load() == nil)
        #expect(await auth.state == .signedOut)
    }

    @Test("初回なのに client_id が返らなければ、登録は完了していないものとして扱う")
    func registrationIncomplete() async throws {
        let key = try TestRSAKey()
        let server = server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0, clientID: nil)] }

        await #expect(throws: ChatGPTSignInError.registrationIncomplete) { try await auth.signIn { await browser.open($0) } }
        #expect(try await store.load() == nil)
    }

    @Test("2回目以降: 保存済みの client_id と違う ID が返ったら拒否する")
    func clientMismatch() async throws {
        let key = try TestRSAKey()
        let server = server(key: key, clientID: ChatGPTFixtures.clientID)
        let existing = ChatGPTFixtures.record(expiresAt: clock.now).withoutTokens()
        let store = InMemoryChatGPTCredentialStore(record: existing)
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0, clientID: "oaiapp_other")] }

        await #expect(throws: ChatGPTSignInError.clientMismatch) { try await auth.signIn { await browser.open($0) } }
        #expect(try await store.load() == existing)
    }

    @Test("2回目以降: 別のアカウント（sub）が返ったら置き換えない")
    func accountMismatch() async throws {
        let key = try TestRSAKey()
        let server = server(key: key, clientID: ChatGPTFixtures.clientID, sub: "someone-else")
        let existing = ChatGPTFixtures.record(expiresAt: clock.now).withoutTokens()
        let store = InMemoryChatGPTCredentialStore(record: existing)
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0, clientID: nil)] }

        await #expect(throws: ChatGPTSignInError.accountMismatch) { try await auth.signIn { await browser.open($0) } }
        #expect(try await store.load() == existing)
    }

    @Test("2回目以降: 同じアカウントなら保存済みの client_id で交換し、記録を置き換える")
    func reauthentication() async throws {
        let key = try TestRSAKey()
        let server = server(key: key, clientID: ChatGPTFixtures.clientID)
        var existing = ChatGPTFixtures.record(expiresAt: clock.now).withoutTokens()
        existing.reauthenticationRequired = true
        let store = InMemoryChatGPTCredentialStore(record: existing)
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0, clientID: nil)] }

        #expect(await auth.loadState() == .needsSignIn(email: "user@example.com"))
        _ = try await auth.signIn { await browser.open($0) }
        #expect(ChatGPTFixtures.formFields(try #require(server.tokenRequests.first))["client_id"] == ChatGPTFixtures.clientID)
        let saved = try #require(try await store.load())
        #expect(saved.accessToken == "access-new")
        #expect(saved.reauthenticationRequired == false)
    }

    @Test("プランの利用のスコープが付与されなければ、ログインは残すが許可なしとする（scope がない応答も同じ）",
          arguments: ["openid profile email", nil] as [String?])
    func scopeNotGranted(scope: String?) async throws {
        let key = try TestRSAKey()
        let server = server(key: key, scope: scope)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0)] }

        #expect(try await auth.signIn { await browser.open($0) } == .signedIn(email: "user@example.com", planUsageGranted: false))
        await #expect(throws: LLMError.chatGPTPlanNotGranted) { try await auth.accessToken() }
    }

    @Test("ID トークンの署名が合わなければ、保存しない")
    func invalidIDTokenSignature() async throws {
        let key = try TestRSAKey()
        let other = try TestRSAKey(kid: key.kid)
        let token = other.sign(payload: [
            "iss": ChatGPTStubServer.issuer, "aud": "oaiapp_new", "exp": clock.now.timeIntervalSince1970 + 3600,
            "nonce": ChatGPTAuthTests.fixedValue, "sub": "x",
        ])
        let jwks = TestRSAKey.jwksJSON([key])
        let server = ChatGPTStubServer(
            token: { _ in .json(200, ChatGPTFixtures.tokenJSON(idToken: token)) },
            jwks: { _ in .json(200, jwks) }
        )
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let browser = FakeBrowser { [Self.callback($0)] }

        await #expect(throws: ChatGPTSignInError.invalidIDToken(.invalidSignature)) { try await auth.signIn { await browser.open($0) } }
        #expect(try await store.load() == nil)
    }

    @Test("知らない kid なら JWKS を1回だけ取り直す")
    func unknownKidRefetchesOnce() async throws {
        let key = try TestRSAKey(kid: "rotated")
        let token = idToken(key: key)
        let jwksResponses = [TestRSAKey.jwksJSON([try TestRSAKey(kid: "old")]), TestRSAKey.jwksJSON([key])]
        let server = ChatGPTStubServer(
            token: { _ in .json(200, ChatGPTFixtures.tokenJSON(idToken: token)) },
            jwks: { attempt in .json(200, jwksResponses[min(attempt, 1)]) }
        )
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)

        // 1回目のログインで古い鍵だけを覚えさせる（知らない kid なので失敗する）。
        let first = FakeBrowser { [Self.callback($0)] }
        await #expect(throws: ChatGPTSignInError.invalidIDToken(.unknownKey)) { try await auth.signIn { await first.open($0) } }
        // 2回目は、覚えている鍵に kid がないので取り直し、成功する。
        let second = FakeBrowser { [Self.callback($0)] }
        _ = try await auth.signIn { await second.open($0) }
        #expect(server.jwksRequests.count == 2)
    }

    @Test("キャンセルすると、何も保存せずに終わる")
    func cancelSignIn() async throws {
        let key = try TestRSAKey()
        let server = server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store)
        let opened = Mutex(false)

        let signingIn = Task { try await auth.signIn { _ in opened.withLock { $0 = true }; return true } }
        await waitUntil { opened.withLock { $0 } }
        await auth.cancelSignIn()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(try await store.load() == nil)
        #expect(await auth.state == .signedOut)
    }

    @Test("時間内にコールバックが来なければ、時間切れで終わる")
    func signInTimeout() async throws {
        let key = try TestRSAKey()
        let server = server(key: key)
        let store = InMemoryChatGPTCredentialStore()
        let auth = makeAuth(server: server, store: store, callbackTimeout: 0.3)

        await #expect(throws: ChatGPTSignInError.timedOut) { try await auth.signIn { _ in true } }
        #expect(try await store.load() == nil)
    }

    @Test("ブラウザを開けなければ、失敗として返す")
    func cannotOpenBrowser() async throws {
        let key = try TestRSAKey()
        let auth = makeAuth(server: server(key: key), store: InMemoryChatGPTCredentialStore())
        await #expect(throws: ChatGPTSignInError.cannotOpenBrowser) { try await auth.signIn { _ in false } }
    }
}
