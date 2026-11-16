import Foundation
import Testing
@testable import LiveMinutesKit

/// OpenAIResponsesClient のテスト。すべて URLProtocol のスタブで応答し、実際の API には接続しない。
@Suite("OpenAIResponsesClient")
struct OpenAIClientTests {
    /// テスト用のキー（実在の形式にしない）
    static let testKey = "test-key-123"

    private func makeClient(
        apiKey: @escaping OpenAIResponsesClient.APIKeyProvider = { OpenAIClientTests.testKey },
        sleeps: SleepRecorder = SleepRecorder(),
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (OpenAIResponsesClient, URL) {
        let url = StubURLProtocol.register(handler)
        let client = OpenAIResponsesClient(
            session: StubURLProtocol.makeSession(),
            endpoint: url,
            apiKey: apiKey,
            // 実際には待たず、待つはずだった時間を記録する。
            sleep: { await sleeps.record($0) }
        )
        return (client, url)
    }

    private func request(effort: String? = "low", timeout: Duration = .seconds(5)) throws -> StructuredOutputRequest {
        StructuredOutputRequest(
            model: "gpt-6-luna",
            instructions: "システムプロンプト",
            input: #"{"new_transcript":[]}"#,
            schemaName: "notes_ops",
            schema: try LLMResources.notesOpsSchema(),
            reasoningEffort: effort,
            timeout: timeout
        )
    }

    /// 構造化出力の成功応答。推論の項目が先に来て、その後に message が来る形。
    static func successBody(outputText: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(outputText), encoding: .utf8)!
        return """
        {"id":"resp_1","object":"response","status":"completed","error":null,"incomplete_details":null,
         "output":[
          {"id":"rs_1","type":"reasoning","summary":[]},
          {"id":"msg_1","type":"message","role":"assistant","status":"completed",
           "content":[{"type":"output_text","text":\(escaped),"annotations":[]}]}
         ]}
        """
    }

    static let opsJSON = #"{"ops":[{"op":"add_topic","topic_id":"new-1","item_id":null,"title":"議題","kind":null,"text":null,"owner":null,"due":null}]}"#

    static func errorBody(code: String?, message: String) -> String {
        let codeJSON = code.map { "\"\($0)\"" } ?? "null"
        return #"{"error":{"message":"\#(message)","type":"invalid_request_error","param":null,"code":\#(codeJSON)}}"#
    }

    // MARK: - 構造化出力

    @Test("成功: message の output_text をつないで返す")
    func success() async throws {
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON)) }
        let output = try await client.structuredOutput(try request())

        #expect(try NotesOpsResponse.decode(from: output).ops.count == 1)
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("リクエストに API キー、モデル、store: false、推論量、スキーマが正しく入る")
    func requestContents() async throws {
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON)) }
        _ = try await client.structuredOutput(try request())

        let sent = try #require(StubURLProtocol.requests(for: url).first)
        #expect(sent.headers["Authorization"] == "Bearer \(Self.testKey)")
        #expect(sent.headers["Content-Type"] == "application/json")

        let body = sent.bodyJSON
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["instructions"] as? String == "システムプロンプト")
        // input はユーザーのメッセージ1件の配列（ChatGPT のプランの利用枠に合わせて、どちらの方式でも配列にする）
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input.first?["role"] as? String == "user")
        #expect(input.first?["content"] as? String == #"{"new_transcript":[]}"#)
        #expect(body["store"] as? Bool == false)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["stream"] == nil)

        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "notes_ops")
        #expect(format["strict"] as? Bool == true)
        let sentSchema = try #require(format["schema"] as? NSDictionary)
        let resourceSchema = try #require(try JSONSerialization.jsonObject(with: LLMResources.notesOpsSchema()) as? NSDictionary)
        #expect(sentSchema == resourceSchema)
    }

    @Test("スキーマはキーの順序を保って送る（op が topic_id より前）")
    func schemaKeyOrder() async throws {
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON)) }
        _ = try await client.structuredOutput(try request())

        let body = try #require(StubURLProtocol.requests(for: url).first).bodyString
        let op = try #require(body.range(of: #""op":{"#) ?? body.range(of: #""op": {"#))
        let topicID = try #require(body.range(of: #""topic_id""#))
        #expect(op.lowerBound < topicID.lowerBound)
    }

    @Test("推論量が nil なら reasoning を送らない")
    func omitsReasoning() async throws {
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON)) }
        _ = try await client.structuredOutput(try request(effort: nil))
        #expect(try #require(StubURLProtocol.requests(for: url).first).bodyJSON["reasoning"] == nil)
    }

    @Test("拒否は refusal になる")
    func refusal() async throws {
        let body = #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"お手伝いできません"}]}]}"#
        let (client, _) = makeClient { _ in .json(200, body) }
        await #expect(throws: LLMError.refusal("お手伝いできません")) { try await client.structuredOutput(try request()) }
    }

    @Test("出力が JSON として壊れていれば invalidOutput")
    func brokenJSON() async throws {
        let (client, _) = makeClient { _ in .json(200, Self.successBody(outputText: #"{"ops":[{"op":"#)) }
        await #expect(throws: LLMError.invalidOutput) { try await client.structuredOutput(try request()) }
    }

    @Test("応答そのものが JSON でなければ invalidOutput")
    func brokenResponse() async throws {
        let (client, _) = makeClient { _ in .json(200, "<html>") }
        await #expect(throws: LLMError.invalidOutput) { try await client.structuredOutput(try request()) }
    }

    @Test("status が incomplete なら理由つきで失敗する")
    func incomplete() async throws {
        let body = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        let (client, _) = makeClient { _ in .json(200, body) }
        await #expect(throws: LLMError.incomplete(reason: "max_output_tokens")) { try await client.structuredOutput(try request()) }
    }

    @Test("status が failed なら failed")
    func failedStatus() async throws {
        let body = #"{"status":"failed","error":{"code":"server_error","message":"boom"},"output":[]}"#
        let (client, _) = makeClient { _ in .json(200, body) }
        await #expect(throws: LLMError.failed(code: "server_error", message: "boom")) { try await client.structuredOutput(try request()) }
    }

    // MARK: - HTTP エラーと再試行

    @Test("401 は再試行せず、認証エラー（応答の文は持たない）")
    func unauthorized() async throws {
        let (client, url) = makeClient { _ in .json(401, Self.errorBody(code: "invalid_api_key", message: "Incorrect API key provided: test****123")) }
        await #expect(throws: LLMError.authentication) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
        #expect(LLMError.authentication.localizedDescription.contains("test****") == false)
    }

    @Test("存在しないモデルは再試行せず、原因が分かる説明になる")
    func modelNotFound() async throws {
        let message = "The model `gpt-0-none` does not exist or you do not have access to it."
        let (client, url) = makeClient { _ in .json(404, Self.errorBody(code: "model_not_found", message: message)) }

        do {
            _ = try await client.structuredOutput(try request())
            Issue.record("失敗するはず")
        } catch let error as LLMError {
            #expect(error == .badRequest(status: 404, code: "model_not_found", message: message))
            #expect(error.localizedDescription.contains("モデルID"))
            #expect(error.localizedDescription.contains("gpt-0-none"))
        }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("400（スキーマの不備など）は再試行せず、API の説明を持つ")
    func badRequest() async throws {
        let (client, url) = makeClient { _ in .json(400, Self.errorBody(code: nil, message: "Invalid schema")) }
        await #expect(throws: LLMError.badRequest(status: 400, code: nil, message: "Invalid schema")) {
            try await client.structuredOutput(try request())
        }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("403 は再試行しない")
    func forbidden() async throws {
        let (client, url) = makeClient { _ in .json(403, Self.errorBody(code: nil, message: "no access")) }
        await #expect(throws: LLMError.permissionDenied(message: "no access")) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("429 と 5xx は再試行し、3回目で成功すれば結果を返す")
    func retriesThenSucceeds() async throws {
        let (client, url) = makeClient { attempt in
            switch attempt {
            case 0: .json(429, Self.errorBody(code: "rate_limit_exceeded", message: "slow down"))
            case 1: .json(503, "{}")
            default: .json(200, Self.successBody(outputText: Self.opsJSON))
            }
        }
        _ = try await client.structuredOutput(try request())
        #expect(StubURLProtocol.requests(for: url).count == 3)
    }

    @Test("再試行は2回まで。3回とも 429 なら rateLimited、5xx なら server")
    func retryLimit() async throws {
        let (client429, url429) = makeClient { _ in .json(429, Self.errorBody(code: "rate_limit_exceeded", message: "x")) }
        await #expect(throws: LLMError.rateLimited) { try await client429.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url429).count == 3)

        let (client500, url500) = makeClient { _ in .json(500, "{}") }
        await #expect(throws: LLMError.server(status: 500)) { try await client500.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url500).count == 3)
    }

    @Test("利用上限の不足（429 insufficient_quota）は再試行しない")
    func insufficientQuota() async throws {
        let (client, url) = makeClient { _ in .json(429, Self.errorBody(code: "insufficient_quota", message: "quota")) }
        await #expect(throws: LLMError.quotaExceeded) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("Retry-After が長すぎれば待たずに失敗し、短ければ再試行する")
    func retryAfter() async throws {
        let (longClient, longURL) = makeClient { _ in .json(429, "{}", headers: ["Retry-After": "30"]) }
        await #expect(throws: LLMError.rateLimited) { try await longClient.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: longURL).count == 1)

        let (shortClient, shortURL) = makeClient { attempt in
            attempt == 0 ? .json(429, "{}", headers: ["Retry-After": "1"]) : .json(200, Self.successBody(outputText: Self.opsJSON))
        }
        _ = try await shortClient.structuredOutput(try request())
        #expect(StubURLProtocol.requests(for: shortURL).count == 2)
    }

    @Test("Retry-After は秒数と HTTP 日付の両方を読める")
    func retryAfterParsing() {
        #expect(OpenAIResponsesClient.retryAfterSeconds("2") == 2)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 1_800_000_000 は 2027-01-15 08:00:00 GMT。
        #expect(OpenAIResponsesClient.retryAfterSeconds("Fri, 15 Jan 2027 08:00:03 GMT", now: now) == 3)
        #expect(OpenAIResponsesClient.retryAfterSeconds("soon", now: now) == nil)
    }

    @Test("通信エラーは再試行する。ネットワークにつながっていない場合は再試行しない")
    func networkErrors() async throws {
        let (flaky, flakyURL) = makeClient { attempt in
            attempt < 2 ? .error(.networkConnectionLost) : .json(200, Self.successBody(outputText: Self.opsJSON))
        }
        _ = try await flaky.structuredOutput(try request())
        #expect(StubURLProtocol.requests(for: flakyURL).count == 3)

        let (offline, offlineURL) = makeClient { _ in .error(.notConnectedToInternet) }
        await #expect(throws: LLMError.network) { try await offline.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: offlineURL).count == 1)
    }

    @Test("締め切りまでに応答がなければ timeout（再試行しない）")
    func deadline() async throws {
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON), delay: 5) }
        let started = ContinuousClock.now
        await #expect(throws: LLMError.timeout) { try await client.structuredOutput(try request(timeout: .milliseconds(200))) }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("URLSession のタイムアウトも timeout になり、再試行しない")
    func urlSessionTimeout() async throws {
        let (client, url) = makeClient { _ in .error(.timedOut) }
        await #expect(throws: LLMError.timeout) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("キャンセルは通信エラーとして再試行しない")
    func cancellation() async throws {
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON), delay: 5) }
        let request = try request()
        let task = Task { try await client.structuredOutput(request) }
        await waitUntil { StubURLProtocol.requests(for: url).count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("API キーがなければ、リクエストを送らずに missingAPIKey")
    func missingKey() async throws {
        let (client, url) = makeClient(apiKey: { throw LLMError.missingAPIKey }) { _ in
            .json(200, Self.successBody(outputText: Self.opsJSON))
        }
        await #expect(throws: LLMError.missingAPIKey) { try await client.structuredOutput(try request()) }
        #expect(StubURLProtocol.requests(for: url).isEmpty)
    }

    @Test("ログ用の要約には、API の説明文や拒否の文を含めない")
    func logSummaryHidesContent() {
        #expect(!LLMError.badRequest(status: 400, code: "x", message: "会議の内容").logSummary.contains("会議"))
        #expect(!LLMError.refusal("会議の内容").logSummary.contains("会議"))
        #expect(!LLMError.failed(code: nil, message: "会議の内容").logSummary.contains("会議"))
        #expect(!LLMError.permissionDenied(message: "会議の内容").logSummary.contains("会議"))
    }

    @Test("再試行の間隔は1秒・2秒。Retry-After があればそれに従う")
    func retryDelays() async throws {
        let backoff = SleepRecorder()
        let (client, _) = makeClient(sleeps: backoff) { _ in .json(503, "{}") }
        await #expect(throws: LLMError.server(status: 503)) { try await client.structuredOutput(try request()) }
        #expect(await backoff.durations == [.seconds(1), .seconds(2)])

        let retryAfter = SleepRecorder()
        let (client2, _) = makeClient(sleeps: retryAfter) { attempt in
            attempt == 0 ? .json(429, "{}", headers: ["Retry-After": "1.5"]) : .json(200, Self.successBody(outputText: Self.opsJSON))
        }
        _ = try await client2.structuredOutput(try request())
        #expect(await retryAfter.durations == [.milliseconds(1500)])
    }

    @Test("instructions と input の引用符・バックスラッシュ・改行・絵文字を正しくエスケープする")
    func bodyEscaping() async throws {
        let tricky = "引用\"符\\と\n改行と\t🎉と</script>"
        let (client, url) = makeClient { _ in .json(200, Self.successBody(outputText: Self.opsJSON)) }
        var request = try request()
        request.instructions = tricky
        request.input = tricky
        _ = try await client.structuredOutput(request)

        let body = try #require(StubURLProtocol.requests(for: url).first).bodyJSON
        #expect(body["instructions"] as? String == tricky)
        #expect((body["input"] as? [[String: Any]])?.first?["content"] as? String == tricky)
    }

    @Test("応答の未知の項目や想定外の形のフィールドは無視して読む")
    func lenientResponse() async throws {
        let escaped = String(data: try JSONEncoder().encode(Self.opsJSON), encoding: .utf8)!
        let body = """
        {"status":"completed","error":null,
         "output":[
          {"type":"reasoning","content":"not-an-array"},
          {"type":"web_search_call","id":1},
          {"type":"message","content":[{"type":"output_text","text":\(escaped),"annotations":7}]}
         ]}
        """
        let (client, _) = makeClient { _ in .json(200, body) }
        _ = try await client.structuredOutput(try request())
    }

    @Test("エラーの code が数値でも読める")
    func numericErrorCode() async throws {
        let (client, _) = makeClient { _ in .json(400, #"{"error":{"message":"bad","code":123}}"#) }
        await #expect(throws: LLMError.badRequest(status: 400, code: "123", message: "bad")) { try await client.structuredOutput(try request()) }
    }

    // MARK: - ストリーミング

    private func sse(_ events: [String]) -> [Data] {
        events.map { Data("event: x\ndata: \($0)\n\n".utf8) }
    }

    private func collect(_ stream: AsyncThrowingStream<String, any Error>) async throws -> String {
        var text = ""
        for try await delta in stream {
            text += delta
        }
        return text
    }

    private let textRequest = TextStreamRequest(model: "gpt-6.1-sol", instructions: "議事録", input: "{}", reasoningEffort: "medium")

    @Test("ストリーミング: 差分を順に返し、response.completed で正常に終わる")
    func streamSuccess() async throws {
        let chunks = sse([
            #"{"type":"response.created","response":{"status":"in_progress"}}"#,
            ##"{"type":"response.output_text.delta","delta":"# 議事"}"##,
            #"{"type":"response.output_text.delta","delta":"録\n"}"#,
            ##"{"type":"response.output_text.done","text":"# 議事録\n"}"##,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
        ])
        let (client, url) = makeClient { _ in .http(status: 200, chunks: chunks) }
        #expect(try await collect(client.streamText(textRequest)) == "# 議事録\n")

        let sent = try #require(StubURLProtocol.requests(for: url).first)
        #expect(sent.bodyJSON["stream"] as? Bool == true)
        #expect(sent.bodyJSON["store"] as? Bool == false)
        #expect(sent.headers["Accept"] == "text/event-stream")
    }

    @Test("ストリーミング: data: の後の空白はなくても読める")
    func streamWithoutSpace() async throws {
        let chunks = [
            Data("data:{\"type\":\"response.output_text.delta\",\"delta\":\"a\"}\n\n".utf8),
            Data("data:{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8),
        ]
        let (client, _) = makeClient { _ in .http(status: 200, chunks: chunks) }
        #expect(try await collect(client.streamText(textRequest)) == "a")
    }

    @Test("ストリーミング: completed を受けずに終われば network（再試行しない）")
    func streamEndsEarly() async throws {
        let chunks = sse([#"{"type":"response.output_text.delta","delta":"途中"}"#])
        let (client, url) = makeClient { _ in .http(status: 200, chunks: chunks) }
        await #expect(throws: LLMError.network) { try await collect(client.streamText(textRequest)) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("ストリーミング: 途中で通信が切れたら network")
    func streamDisconnects() async throws {
        // 差分を受け取る前に切れた場合は再試行することがある（URLSession が切断を先に伝える場合）。
        // どちらでも、最後は network で終わる。
        let chunks = sse([#"{"type":"response.output_text.delta","delta":"途中"}"#])
        let (client, url) = makeClient { _ in .http(status: 200, chunks: chunks, failure: .networkConnectionLost) }
        await #expect(throws: LLMError.network) { try await collect(client.streamText(textRequest)) }
        #expect((1...3).contains(StubURLProtocol.requests(for: url).count))
    }

    @Test("ストリーミング: 差分を渡した後に切れたら、再試行しない（同じ文が重複するため）")
    func streamDoesNotRetryAfterDelta() async throws {
        // 1回目は差分を渡し、少し待ってから通信エラーで切る（差分を受け取った後に切れる）。
        // 再試行すれば2回目で成功してしまう。
        let (client, url) = makeClient { attempt in
            attempt == 0
                ? .http(status: 200, chunks: self.sse([#"{"type":"response.output_text.delta","delta":"途中"}"#]),
                        failure: .networkConnectionLost, failureDelay: 0.3)
                : .http(status: 200, chunks: self.sse([
                    #"{"type":"response.output_text.delta","delta":"全部"}"#,
                    #"{"type":"response.completed","response":{"status":"completed"}}"#,
                ]))
        }
        var received: [String] = []
        await #expect(throws: LLMError.network) {
            for try await delta in client.streamText(textRequest) {
                received.append(delta)
            }
        }
        #expect(received == ["途中"])
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("ストリーミング: U+2028 などを含む差分も、行の途中で切らずに読む")
    func streamWithLineSeparatorCharacters() async throws {
        let chunks = [
            Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"前\u{2028}後\u{85}末\"}\r\n\r\n".utf8),
            Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\r\n\r\n".utf8),
        ]
        let (client, _) = makeClient { _ in .http(status: 200, chunks: chunks) }
        #expect(try await collect(client.streamText(textRequest)) == "前\u{2028}後\u{85}末")
    }

    @Test("ストリーミング: 一行が複数のチャンクに分かれて届いても読める")
    func streamSplitAcrossChunks() async throws {
        let line = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"分割\"}\n\n"
        let bytes = Data(line.utf8)
        let chunks = [bytes.prefix(10), bytes.dropFirst(10).prefix(7), bytes.dropFirst(17)].map { Data($0) }
            + sse([#"{"type":"response.completed","response":{"status":"completed"}}"#])
        let (client, _) = makeClient { _ in .http(status: 200, chunks: chunks) }
        #expect(try await collect(client.streamText(textRequest)) == "分割")
    }

    @Test("ストリーミング: completed の response の形が想定と違っても、完了として扱う")
    func streamLenientCompleted() async throws {
        let chunks = sse([
            #"{"type":"response.output_text.delta","delta":"ok"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":"unexpected"}}"#,
        ])
        let (client, _) = makeClient { _ in .http(status: 200, chunks: chunks) }
        #expect(try await collect(client.streamText(textRequest)) == "ok")
    }

    @Test("ストリーミング: incomplete、type のない error、URLSession のタイムアウト")
    func streamOtherFailures() async throws {
        let (incomplete, _) = makeClient { _ in
            .http(status: 200, chunks: self.sse([#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#]))
        }
        await #expect(throws: LLMError.incomplete(reason: "max_output_tokens")) { try await collect(incomplete.streamText(textRequest)) }

        let (untyped, _) = makeClient { _ in
            .http(status: 200, chunks: self.sse([#"{"error":{"code":"server_error","message":"boom"}}"#]))
        }
        await #expect(throws: LLMError.failed(code: "server_error", message: "boom")) { try await collect(untyped.streamText(textRequest)) }

        let (timedOut, url) = makeClient { _ in .error(.timedOut) }
        await #expect(throws: LLMError.timeout) { try await collect(timedOut.streamText(textRequest)) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("ストリーミング: 429 で Retry-After が長ければ待たずに失敗する")
    func streamLongRetryAfter() async throws {
        let (client, url) = makeClient { _ in .json(429, "{}", headers: ["Retry-After": "60"]) }
        await #expect(throws: LLMError.rateLimited) { try await collect(client.streamText(textRequest)) }
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("ストリーミング: 読む側がやめたら、通信も止まる")
    func streamCancelledByConsumer() async throws {
        let (client, url) = makeClient { _ in
            .http(status: 200, chunks: self.sse([#"{"type":"response.output_text.delta","delta":"a"}"#]), delay: 5)
        }
        let request = textRequest
        let task = Task {
            var text = ""
            for try await delta in client.streamText(request) { text += delta }
            return text
        }
        await waitUntil { StubURLProtocol.requests(for: url).count == 1 }
        let started = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(StubURLProtocol.requests(for: url).count == 1)
    }

    @Test("ストリーミング: 401 は認証エラー、error イベントと failed は failed、拒否は refusal")
    func streamErrors() async throws {
        let (unauthorized, _) = makeClient { _ in .json(401, Self.errorBody(code: "invalid_api_key", message: "x")) }
        await #expect(throws: LLMError.authentication) { try await collect(unauthorized.streamText(textRequest)) }

        let (errorEvent, _) = makeClient { _ in
            .http(status: 200, chunks: self.sse([#"{"type":"error","code":"server_error","message":"boom","param":null}"#]))
        }
        await #expect(throws: LLMError.failed(code: "server_error", message: "boom")) { try await collect(errorEvent.streamText(textRequest)) }

        let (failed, _) = makeClient { _ in
            .http(status: 200, chunks: self.sse([#"{"type":"response.failed","response":{"status":"failed","error":{"code":"x","message":"y"}}}"#]))
        }
        await #expect(throws: LLMError.failed(code: "x", message: "y")) { try await collect(failed.streamText(textRequest)) }

        let (refused, _) = makeClient { _ in
            .http(status: 200, chunks: self.sse([
                #"{"type":"response.refusal.delta","delta":"できません"}"#,
                #"{"type":"response.completed","response":{"status":"completed"}}"#,
            ]))
        }
        await #expect(throws: LLMError.refusal("できません")) { try await collect(refused.streamText(textRequest)) }
    }

    @Test("ストリーミング: 始まる前の 5xx は再試行する")
    func streamRetriesBeforeFirstDelta() async throws {
        let chunks = sse([
            #"{"type":"response.output_text.delta","delta":"ok"}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
        ])
        let (client, url) = makeClient { attempt in
            attempt == 0 ? .json(502, "{}") : .http(status: 200, chunks: chunks)
        }
        #expect(try await collect(client.streamText(textRequest)) == "ok")
        #expect(StubURLProtocol.requests(for: url).count == 2)
    }
}

/// 再試行で待つはずだった時間を記録する。
actor SleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}
