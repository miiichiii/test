import Foundation
import Testing
@testable import LiveMinutesKit

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "LiveMinutesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("既定値: モデルIDは Luna / Sol、認識言語は ja-JP、送信条件は設計書の値")
    func defaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.liveModelID == "gpt-6-luna")
        #expect(settings.finalModelID == "gpt-6.1-sol")
        #expect(settings.liveReasoningEffort == "low")
        #expect(settings.finalReasoningEffort == "medium")
        #expect(settings.recognitionLocaleIdentifier == "ja-JP")
        #expect(settings.notesMinCharacters == 120)
        #expect(settings.notesMaxInterval == 20)
        #expect(settings.notesMinInterval == 8)
        #expect(settings.glossary.isEmpty)
    }

    @Test("変更は UserDefaults に保存され、作り直しても残る")
    func persists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.liveModelID = "custom-luna"
        settings.finalModelID = "custom-sol"
        settings.recognitionLocaleIdentifier = "en-US"
        settings.glossary = ["LiveMinutes"]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.liveModelID == "custom-luna")
        #expect(reloaded.finalModelID == "custom-sol")
        #expect(reloaded.recognitionLocaleIdentifier == "en-US")
        #expect(reloaded.glossary == ["LiveMinutes"])
    }

    @Test("認識言語の表記をそろえる（ja_JP → ja-JP）")
    func normalizesLocale() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.recognitionLocaleIdentifier = "ja_JP"
        #expect(settings.recognitionLocaleIdentifier == "ja-JP")
        #expect(AppSettings.normalizedLocaleIdentifier("en_US") == "en-US")
    }

    @Test("API キーは UserDefaults に書かない")
    func noAPIKeyInDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.liveModelID = "x"
        let keys = defaults.persistentDomain(forName: suite)?.keys.map { $0.lowercased() } ?? []
        #expect(!keys.contains { $0.contains("key") && $0.contains("api") })
    }

    @Test("リクエストに使うモデルIDは前後の空白を除く")
    func effectiveModelIDs() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.liveModelID = " gpt-6-luna \n"
        settings.finalModelID = "\tgpt-6.1-sol "
        #expect(settings.effectiveLiveModelID == "gpt-6-luna")
        #expect(settings.effectiveFinalModelID == "gpt-6.1-sol")
    }

    @Test("推論量は空なら nil")
    func effort() {
        #expect(AppSettings.effort(" ") == nil)
        #expect(AppSettings.effort("low") == "low")
    }
}

@Suite("SecretStore")
struct SecretStoreTests {
    @Test("メモリ上の実装: 前後の空白と改行を除いて保存し、空は拒否する")
    func inMemory() async throws {
        let store = InMemorySecretStore()
        #expect(await store.hasAPIKey() == false)
        await #expect(throws: LLMError.missingAPIKey) { try await store.readAPIKey() }
        await #expect(throws: KeychainStore.KeychainError.emptyKey) { try await store.saveAPIKey(" \n") }

        try await store.saveAPIKey("  test-key\n")
        #expect(try await store.readAPIKey() == "test-key")
        try await store.deleteAPIKey()
        #expect(await store.hasAPIKey() == false)
    }

    /// 実際のログインキーチェーンに触るので、`LIVEMINUTES_KEYCHAIN_TEST=1` のときだけ動かす。
    /// 本番と別の service 名を使い、最後に消す。
    @Test("KeychainStore: 保存・読み出し・削除（環境変数で有効にしたときだけ）",
          .enabled(if: ProcessInfo.processInfo.environment["LIVEMINUTES_KEYCHAIN_TEST"] == "1"))
    func keychain() async throws {
        let store = KeychainStore(service: "com.example.LiveMinutes.tests.\(UUID().uuidString)")
        defer { Task { try? await store.deleteAPIKey() } }

        #expect(await store.hasAPIKey() == false)
        await #expect(throws: LLMError.missingAPIKey) { try await store.readAPIKey() }
        try await store.saveAPIKey(" test-key-1 \n")
        #expect(await store.hasAPIKey())
        #expect(try await store.readAPIKey() == "test-key-1")
        // 上書きできる。
        try await store.saveAPIKey("test-key-2")
        #expect(try await store.readAPIKey() == "test-key-2")
        try await store.deleteAPIKey()
        #expect(await store.hasAPIKey() == false)
    }
}

/// 決められた結果を返す偽の LLMClient。
actor FakeLLMClient: LLMClient {
    private let result: @Sendable (StructuredOutputRequest) throws -> Data
    private(set) var requests: [StructuredOutputRequest] = []

    init(result: @escaping @Sendable (StructuredOutputRequest) throws -> Data) {
        self.result = result
    }

    func structuredOutput(_ request: StructuredOutputRequest) async throws -> Data {
        requests.append(request)
        return try result(request)
    }

    nonisolated func streamText(_ request: TextStreamRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
@Suite("接続テスト")
struct ConnectionTestTests {
    @Test("ノートのスキーマで構造化出力を1回求め、ノートの形で読めれば成功")
    func success() async throws {
        let client = FakeLLMClient { _ in Data(#"{"ops":[]}"#.utf8) }
        let test = ConnectionTest(client: client)

        await test.run(model: " gpt-6-luna ", reasoningEffort: "low")
        #expect(test.status == .succeeded)
        let request = try #require(await client.requests.first)
        #expect(request.model == "gpt-6-luna")
        #expect(request.schemaName == "notes_ops")
        #expect(request.schema == (try LLMResources.notesOpsSchema()))
        #expect(request.reasoningEffort == "low")
        #expect(await client.requests.count == 1)
    }

    @Test("モデルIDが空なら送らずに案内する")
    func emptyModel() async {
        let client = FakeLLMClient { _ in Data() }
        let test = ConnectionTest(client: client)
        await test.run(model: "  ", reasoningEffort: "")
        #expect(test.status == .failed("モデルIDを入力してください。"))
        #expect(await client.requests.isEmpty)
    }

    @Test("失敗の理由を日本語で表示する", arguments: [LLMError.authentication, .missingAPIKey, .badRequest(status: 404, code: "model_not_found", message: "m")])
    func failure(error: LLMError) async {
        let test = ConnectionTest(client: FakeLLMClient { _ in throw error })
        await test.run(model: "gpt-6-luna", reasoningEffort: "low")
        #expect(test.status == .failed(error.localizedDescription))
    }

    @Test("応答がノートの形と合わなければ失敗")
    func mismatchedOutput() async {
        let test = ConnectionTest(client: FakeLLMClient { _ in Data(#"{"answer":1}"#.utf8) })
        await test.run(model: "gpt-6-luna", reasoningEffort: "low")
        #expect(test.status == .failed("応答がノートの形式と合いませんでした。"))
    }
}

@Suite("LLMResources")
struct LLMResourcesTests {
    @Test("プロンプト2つとスキーマを読める")
    func loads() throws {
        #expect(try LLMResources.liveNotesSystemPrompt().contains("差分操作"))
        #expect(!(try LLMResources.finalMinutesSystemPrompt().isEmpty))
        #expect(!(try LLMResources.notesOpsSchema().isEmpty))
    }

    @Test("スキーマは strict モードの決まりに沿っている（全プロパティ必須、additionalProperties: false、enum に null を入れない）")
    func schemaFollowsStrictRules() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: LLMResources.notesOpsSchema()) as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["anyOf"] == nil)
        #expect(schema["additionalProperties"] as? Bool == false)

        let ops = try #require((schema["properties"] as? [String: Any])?["ops"] as? [String: Any])
        let item = try #require(ops["items"] as? [String: Any])
        let properties = try #require(item["properties"] as? [String: Any])
        let required = try #require(item["required"] as? [String])
        #expect(Set(required) == Set(properties.keys))
        #expect(item["additionalProperties"] as? Bool == false)

        let kind = try #require(properties["kind"] as? [String: Any])
        let branches = try #require(kind["anyOf"] as? [[String: Any]])
        #expect(branches.contains { ($0["enum"] as? [String]) == NoteKind.allCases.map(\.rawValue) })
        #expect(branches.contains { $0["type"] as? String == "null" })
    }
}
