import Foundation
import Security

/// ChatGPT のログインの記録（DESIGN.md §4.11）。キーチェーンに JSON で1項目だけ置く。
///
/// トークンを捨てても `clientID` と `subject` は残す（次のログインで同じアカウントかを確かめるため）。
/// 値は文字列にしても出ない。
public struct ChatGPTCredentialRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 発行された client_id（`oaiapp_…`）。アカウント（ワークスペース）ごとの登録
    public var clientID: String
    /// 検証した ID トークンの `sub`
    public var subject: String
    public var email: String?
    public var idToken: String?
    public var accessToken: String?
    public var refreshToken: String?
    /// アクセストークンの期限（壁時計）
    public var accessTokenExpiresAt: Date?
    /// トークンの応答の `earliest_refresh_at`（意味は文書に説明がない。これより前の更新は、期限が迫るまで控える）
    public var earliestRefreshAt: Date?
    /// 付与されたスコープ
    public var scopes: [String]
    /// 更新が終端のエラーになり、ログインし直しが必要（ログアウトでトークンを消したときは false）
    public var reauthenticationRequired: Bool

    public init(
        clientID: String,
        subject: String,
        email: String?,
        idToken: String?,
        accessToken: String?,
        refreshToken: String?,
        accessTokenExpiresAt: Date?,
        earliestRefreshAt: Date?,
        scopes: [String],
        reauthenticationRequired: Bool = false
    ) {
        self.clientID = clientID
        self.subject = subject
        self.email = email
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.earliestRefreshAt = earliestRefreshAt
        self.scopes = scopes
        self.reauthenticationRequired = reauthenticationRequired
    }

    /// トークンを持っているか（ログイン済みか）
    public var hasTokens: Bool { accessToken != nil && refreshToken != nil }

    /// プランの利用が許可されているか
    public var planUsageGranted: Bool { scopes.contains(ChatGPTAuth.planUsageScope) }

    /// トークンだけを除いた記録（ログアウトや終端のエラーのとき）
    /// - Parameter keepingIDToken: 終端のエラーでは ID トークンを残す（次のログインの `id_token_hint` に使う）。
    ///   ログアウトでは消す（文書の指示: ログアウトの後は `id_token_hint` を付けない）
    func withoutTokens(keepingIDToken: Bool = false) -> ChatGPTCredentialRecord {
        var copy = self
        if !keepingIDToken { copy.idToken = nil }
        copy.accessToken = nil
        copy.refreshToken = nil
        copy.accessTokenExpiresAt = nil
        copy.earliestRefreshAt = nil
        return copy
    }

    public var description: String {
        "ChatGPTCredentialRecord(hasTokens: \(hasTokens), planUsageGranted: \(planUsageGranted))"
    }

    public var debugDescription: String { description }
}

/// ログインの記録の保存先。テストではメモリ上の実装に差し替える。
public protocol ChatGPTCredentialStore: Sendable {
    /// 記録を読む。ない場合は nil。読めない場合（アクセスを拒否された、など）は `LLMError.chatGPTCredentialUnavailable` を投げる
    func load() async throws -> ChatGPTCredentialRecord?
    func save(_ record: ChatGPTCredentialRecord) async throws
    func delete() async throws
}

/// 従来のキーチェーン（ログインキーチェーン）に、汎用パスワードとして JSON を保存する。API キーとは別の項目。
///
/// 書き換えは `SecItemUpdate` を先に試す（消してから追加する方式は、その間にアプリが落ちるとログインし直しになるため。
/// トークンは1時間ごとに書き換わる）。キーチェーンの操作は許可ダイアログの間止まるので、メインスレッドでは行わない。
public struct KeychainChatGPTCredentialStore: ChatGPTCredentialStore {
    public static let defaultService = "com.example.LiveMinutes.chatgpt"
    static let account = "chatgpt-credentials"

    private let service: String

    public init(service: String = KeychainChatGPTCredentialStore.defaultService) {
        self.service = service
    }

    public func load() async throws -> ChatGPTCredentialRecord? {
        try await Self.load(service: service)
    }

    public func save(_ record: ChatGPTCredentialRecord) async throws {
        try await Self.save(record, service: service)
    }

    public func delete() async throws {
        try await Self.delete(service: service)
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    @concurrent
    private static func load(service: String) async throws -> ChatGPTCredentialRecord? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw LLMError.chatGPTCredentialUnavailable }
            guard let record = try? decoder.decode(ChatGPTCredentialRecord.self, from: data) else {
                // 壊れた記録は使わない（ログインし直してもらう）。
                return nil
            }
            return record
        case errSecItemNotFound:
            return nil
        default:
            throw LLMError.chatGPTCredentialUnavailable
        }
    }

    @concurrent
    private static func save(_ record: ChatGPTCredentialRecord, service: String) async throws {
        let data = try encoder.encode(record)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(service: service) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(service: service)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "LiveMinutes: ChatGPT のログイン"
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStore.KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainStore.KeychainError.unexpectedStatus(status)
        }
    }

    @concurrent
    private static func delete(service: String) async throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStore.KeychainError.unexpectedStatus(status)
        }
    }
}

/// メモリ上に持つ保存先（テストとプレビュー用）。
public actor InMemoryChatGPTCredentialStore: ChatGPTCredentialStore {
    private var record: ChatGPTCredentialRecord?
    /// true にすると、読み出しで `chatGPTCredentialUnavailable` を投げる（アクセスを拒否された場合のテスト）
    public var failsToLoad = false
    /// true にすると、保存で失敗する
    public var failsToSave = false
    public private(set) var saveCount = 0

    public init(record: ChatGPTCredentialRecord? = nil) {
        self.record = record
    }

    public func load() async throws -> ChatGPTCredentialRecord? {
        if failsToLoad { throw LLMError.chatGPTCredentialUnavailable }
        return record
    }

    public func save(_ record: ChatGPTCredentialRecord) async throws {
        if failsToSave { throw KeychainStore.KeychainError.unexpectedStatus(errSecIO) }
        self.record = record
        saveCount += 1
    }

    public func delete() async throws {
        record = nil
    }

    /// 別のプロセスが書き換えた状態を作る（テスト用）
    public func replace(with record: ChatGPTCredentialRecord?) {
        self.record = record
    }

    public func setFailsToLoad(_ value: Bool) { failsToLoad = value }
    public func setFailsToSave(_ value: Bool) { failsToSave = value }
}

/// ホストID（`ext_agent_host_id`）。秘密ではないので `UserDefaults` に置く。
public struct ChatGPTHostIDStore: Sendable {
    static let key = "LiveMinutes.chatGPTHostID"
    // UserDefaults はスレッドセーフ（Apple のドキュメント）だが Sendable ではないので、suite の名前だけを持つ。
    private let suiteName: String?

    /// - Parameter suiteName: テストでは専用の suite の名前を渡す。nil なら `.standard`
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// 保存済みの値を返す。なければ `urn:uuid:<UUID>` を作って保存する。
    public func hostID() -> String {
        if let existing = defaults.string(forKey: Self.key), !existing.isEmpty {
            return existing
        }
        let created = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(created, forKey: Self.key)
        return created
    }
}
