import Foundation
import Testing
@testable import LiveMinutesKit

/// ChatGPT のプランの利用枠で送るときの OpenAIResponsesClient のテスト（DESIGN.md §4.11）。
/// すべて URLProtocol のスタブで応答し、実際の API には接続しない。
@Suite("OpenAIResponsesClient（ChatGPT のプラン）")
struct ChatGPTClientTests {
    /// 偽の資格情報。401 を受けたときの返事と、次に返すトークンを決められる。
    actor FakeCredentials: CredentialProvider {
        var current: LLMCredential
        var nextAfterUnauthorized: LLMCredential?
        var credentialError: LLMError?
        /// 401 を知らされた後、credential() でこのエラーを投げる（更新が終端のエラーだった場合）
        var errorAfterUnauthorized: LLMError?
        private(set) var unauthorizedCalls: [LLMCredential] = []

        init(_ current: LLMCredential, nextAfterUnauthorized: LLMCredential? = nil) {
            self.current = current
            self.nextAfterUnauthorized = nextAfterUnauthorized
        }

        func credential() async throws -> LLMCredential {
            if let credentialError { throw credentialError }
            return current
        }

        func handleUnauthorized(_ used: LLMCredential) async -> Bool {
            unauthorizedCalls.append(used)
            if let errorAfterUnauthorized { credentialError = errorAfterUnauthorized }
            guard let next = nextAfterUnauthorized else { return false }
            current = next
            nextAfterUnauthorized = nil
            return true
        }

        func setErrorAfterUnauthorized(_ error: LLMError?) { errorAfterUnauthorized = error }
    }

    private func makeClient(
        credentials: any CredentialProvider,
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (OpenAIResponsesClient, URL) {
        let url = StubURLProtocol.register(handler)
        let client = OpenAIResponsesClient(
            session: StubURLProtocol.makeSession(),
            endpoint: url,
            credentials: credentials,
            sleep: { _ in }
        )
        return (client, url)
    }

    private func request(effort: String? = "low") throws -> StructuredOutputRequest {
        StructuredOutputRequest(
            model: "gpt-6-luna",
            instructions: "システムプロンプト",
            input: #"{"new_transcript":[]}"#,
            schemaName: "notes_ops",
            schema: try LLMResources.notesOpsSchema(),
            reasoningEffort: effort,
            timeout: .seconds(5)
        )
    }

    static func sse(_ events: [String]) -> Data {
        Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }

    static func delta(_ text: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return #"{"type":"response.output_text.delta","delta":\#(escaped)}"#
    }

    static let completed = #"{"type":"response.completed","response":{"status":"completed"}}"#

    /// 構造化出力の JSON を2つに分けて流し、完了で終わるストリーム
    static func opsStream() -> StubURLProtocol.Stub {
        let json = OpenAIClientTests.opsJSON
        let middle = json.index(json.startIndex, offsetBy: json.count / 2)
        return .http(status: 200, chunks: [sse([delta(String(json[..<middle])), delta(String(json[middle...])), completed])])
    }

    static func error(_ status: Int, code: String, param: String? = nil, message: String = "m") -> StubURLProtocol.Stub {
        let paramJSON = param.map { "\"\($0)\"" } ?? "null"
        return .json(status, #"{"error":{"message":"\#(message)","type":"x","param":\#(paramJSON),"code":"\#(code)"}}"#)
    }

    // MARK: - リクエストの形

    @Test("構造化出力を stream: true・store: false・配列の input で送り、差分をつないで読む")
    func structuredOverStream() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token-1"))
        let (client, url) = makeClient(credentials: credentials) { _ in Self.opsStream() }
        let output = try await client.structuredOutput(try request())

        #expect(try NotesOpsResponse.decode(from: output).ops.count == 1)
        let sent = try #require(StubURLProtocol.requests(for: url).first)
        #expect(sent.headers["Authorization"] == "Bearer token-1")
        #expect(sent.headers["Accept"] == "text/event-stream")
        let body = sent.bodyJSON
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect((body["input"] as? [[String: Any]])?.first?["role"] as? String == "user")
        #expect(((body["text"] as? [String: Any])?["format"] as? [String: Any])?["strict"] as? Bool == true)
        for unsupported in ["max_output_tokens", "temperature", "metadata", "user", "previous_response_id"] {
            #expect(body[unsupported] == nil)
        }
    }

    @Test("API キーの構造化出力は、これまでどおりストリーミングにしない")
    func apiKeyIsNotStreamed() async throws {
        let credentials = FakeCredentials(.apiKey("test-key"))
        let (client, url) = makeClient(credentials: credentials) { _ in
            .json(200, OpenAIClientTests.successBody(outputText: OpenAIClientTests.opsJSON))
        }
        _ = try await client.structuredOutput(try request())
        #expect(try #require(StubURLProtocol.requests(for: url).first).bodyJSON["stream"] == nil)
    }

    @Test("ストリームが途中で切れたら、集めた差分を捨てて送り直す（差分を外に出していないため）")
    func structuredStreamRetriesAfterPartialOutput() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token-1"))
        let (client, url) = makeClient(credentials: credentials) { attempt in
            attempt == 0
                ? .http(status: 200, chunks: [Self.sse([Self.delta("{\"ops\":")])], failure: .networkConnectionLost)
                : Self.opsStream()
        }
        let output = try await client.structuredOutput(try request())
        #expect(try NotesOpsResponse.decode(from: output).ops.count == 1)
        #expect(StubURLProtocol.requests(for: url).count == 2)
    }

    // MARK: - 401

    @Test("401 を受けたら資格情報を更新して1回だけ送り直す")
    func unauthorizedRetriesOnce() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "old"), nextAfterUnauthorized: .chatGPTPlan(accessToken: "new"))
        let (client, url) = makeClient(credentials: credentials) { attempt in
            attempt == 0 ? .json(401, #"{"detail":"unauthorized"}"#) : Self.opsStream()
        }
        _ = try await client.structuredOutput(try request())

        let sent = StubURLProtocol.requests(for: url)
        #expect(sent.map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new"])
        #expect(await credentials.unauthorizedCalls == [.chatGPTPlan(accessToken: "old")])
    }

    @Test("更新した後もまた 401 なら、送り直さずに chatGPTUnauthorized")
    func unauthorizedTwice() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "old"), nextAfterUnauthorized: .chatGPTPlan(accessToken: "new"))
        let (client, url) = makeClient(credentials: credentials) { _ in
            Self.error(401, code: "subscription_sharing_invalid_user")
        }
        await #expect(throws: LLMError.chatGPTUnauthorized) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 2)
        #expect(await credentials.unauthorizedCalls.count == 1)
    }

    @Test("更新が終端のエラーだったら、ログインし直しが必要と伝える")
    func unauthorizedAndSignInRequired() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "old"))
        // 1回目の credential() は成功し、401 の後の確認では要ログインになる。
        await credentials.setErrorAfterUnauthorized(.chatGPTSignInRequired)
        let (client, url) = makeClient(credentials: credentials) { _ in .json(401, "{}") }
        await #expect(throws: LLMError.chatGPTSignInRequired) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("401 の後に接続方法が変わっていたら、送り直さない")
    func unauthorizedWithChangedMethod() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "old"), nextAfterUnauthorized: .apiKey("key"))
        let (client, url) = makeClient(credentials: credentials) { _ in .json(401, "{}") }
        await #expect(throws: LLMError.chatGPTUnauthorized) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    // MARK: - reasoning

    @Test("reasoning が使えないと言われたら、外して1回だけ送り直し、以後も外す")
    func dropsReasoning() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let (client, url) = makeClient(credentials: credentials) { attempt in
            attempt == 0
                ? Self.error(400, code: "subscription_sharing_unsupported_capability", param: "reasoning.effort")
                : Self.opsStream()
        }
        _ = try await client.structuredOutput(try request())
        _ = try await client.structuredOutput(try request())

        let bodies = StubURLProtocol.requests(for: url).map(\.bodyJSON)
        #expect(bodies.count == 3)
        #expect(bodies[0]["reasoning"] != nil)
        #expect(bodies[1]["reasoning"] == nil)
        #expect(bodies[2]["reasoning"] == nil)
    }

    @Test("reasoning 以外の使えない指定は、送り直さずに使えなかったパラメータを伝える")
    func unsupportedOtherParam() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let (client, url) = makeClient(credentials: credentials) { _ in
            Self.error(400, code: "subscription_sharing_unsupported_capability", param: "text.format")
        }
        await #expect(throws: LLMError.unsupportedCapability(param: "text.format")) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
        #expect(LLMError.unsupportedCapability(param: "text.format").localizedDescription.contains("text.format"))
    }

    // MARK: - エラーの対応付け

    @Test("HTTP のエラーコードを対応付ける。一時的なものだけ再試行する", arguments: [
        (429, "subscription_sharing_usage_limit_exceeded", LLMError.usageLimitReached, 1),
        (503, "subscription_sharing_usage_unavailable", LLMError.planUsageUnavailable, 3),
        (503, "subscription_sharing_user_unavailable", LLMError.planUsageUnavailable, 3),
        (403, "subscription_sharing_user_not_eligible", LLMError.planNotEligible(message: "m"), 1),
        (403, "chatpass_v2_scope_not_authorized", LLMError.chatGPTRejected(code: "chatpass_v2_scope_not_authorized"), 1),
        (403, "subscription_sharing_route_not_supported", LLMError.chatGPTRejected(code: "subscription_sharing_route_not_supported"), 1),
    ])
    func httpErrorCodes(status: Int, code: String, expected: LLMError, requestCount: Int) async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let (client, url) = makeClient(credentials: credentials) { _ in Self.error(status, code: code) }
        await #expect(throws: expected) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == requestCount)
    }

    @Test("ストリームの途中の response.failed でも、ChatGPT のコードを同じに対応付ける", arguments: [
        ("subscription_sharing_usage_limit_exceeded", LLMError.usageLimitReached),
        ("subscription_sharing_usage_unavailable", LLMError.planUsageUnavailable),
        ("server_error", LLMError.failed(code: "server_error", message: "m")),
    ])
    func midStreamFailure(code: String, expected: LLMError) async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let failed = #"{"type":"response.failed","response":{"status":"failed","error":{"code":"\#(code)","message":"m"}}}"#
        let (client, _) = makeClient(credentials: credentials) { _ in
            .http(status: 200, chunks: [Self.sse([Self.delta("{"), failed])])
        }
        await #expect(throws: expected) { try await client.structuredOutput(try request()) }
    }

    @Test("ストリームが始まる前の {\"detail\": …} は、ステータスだけで分類し、文を添える")
    func detailBody() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let (client, _) = makeClient(credentials: credentials) { _ in .json(403, #"{"detail":"region not permitted"}"#) }
        await #expect(throws: LLMError.permissionDenied(message: "region not permitted")) {
            try await client.structuredOutput(try request())
        }
    }

    @Test("使用量の上限は、一般の 429（再試行の対象）と区別する")
    func usageLimitIsNotRateLimit() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let (client, url) = makeClient(credentials: credentials) { _ in
            Self.error(429, code: "subscription_sharing_usage_limit_exceeded")
        }
        await #expect(throws: LLMError.usageLimitReached) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    // MARK: - モデル一覧

    @Test("モデル一覧は models 配列の visibility が list のものだけ。API キーのときは nil")
    func modelList() async throws {
        let credentials = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let (client, url) = makeClient(credentials: credentials) { _ in Self.opsStream() }
        let modelsURL = url.deletingLastPathComponent().appending(path: "models")
        StubURLProtocol.register(at: modelsURL) { _ in
            .json(200, #"{"models":[{"slug":"gpt-6-luna","display_name":"Luna","visibility":"list"},{"slug":"internal","visibility":"hide"},{"slug":"gpt-6.1-sol","visibility":"list"}]}"#)
        }
        #expect(try await client.chatGPTModelSlugs() == ["gpt-6-luna", "gpt-6.1-sol"])
        #expect(StubURLProtocol.requests(for: modelsURL).first?.headers["Authorization"] == "Bearer token")

        let apiKeyClient = OpenAIResponsesClient(
            session: StubURLProtocol.makeSession(),
            endpoint: url,
            credentials: FakeCredentials(.apiKey("key")),
            sleep: { _ in }
        )
        #expect(try await apiKeyClient.chatGPTModelSlugs() == nil)
    }

    // MARK: - 資格情報

    @Test("CredentialRouter は接続方法に従い、401 は送った時点の方式の担当へ渡す")
    @MainActor
    func router() async throws {
        let apiKey = FakeCredentials(.apiKey("key"))
        let chatGPT = FakeCredentials(.chatGPTPlan(accessToken: "token"))
        let box = MethodBox()
        let router = CredentialRouter(method: { box.method }, apiKey: apiKey, chatGPT: chatGPT)

        #expect(try await router.credential() == .apiKey("key"))
        box.method = .chatGPTPlan
        #expect(try await router.credential() == .chatGPTPlan(accessToken: "token"))

        // 接続方法が ChatGPT に変わった後に、API キーで送ったリクエストの 401 が届いた。
        _ = await router.handleUnauthorized(.apiKey("key"))
        #expect(await apiKey.unauthorizedCalls.count == 1)
        #expect(await chatGPT.unauthorizedCalls.isEmpty)
    }

    @Test("資格情報は文字列にしても値が出ない")
    func credentialRedaction() {
        let values: [LLMCredential] = [.apiKey("secret-key-value"), .chatGPTPlan(accessToken: "secret-token-value")]
        for credential in values {
            #expect(!String(describing: credential).contains("secret"))
            #expect(!String(reflecting: credential).contains("secret"))
            #expect(!"\(credential)".contains("secret"))
        }
    }
}

@MainActor
final class MethodBox {
    var method: AuthMethod = .apiKey
}
