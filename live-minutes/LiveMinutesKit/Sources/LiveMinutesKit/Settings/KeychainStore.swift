import Foundation
import Security

/// API キーの保存先（DESIGN.md §4.8）。テストではメモリ上の実装に差し替える。
///
/// API キーは Keychain 以外（UserDefaults、ファイル、ログ）には書かない。
public protocol SecretStore: Sendable {
    /// API キーが保存されているか（値は読まない）
    func hasAPIKey() async -> Bool
    /// API キーを読む。ない場合は `LLMError.missingAPIKey`、読めない場合は `LLMError.apiKeyUnavailable` を投げる
    func readAPIKey() async throws -> String
    /// 前後の空白と改行を除いて保存する。空なら `KeychainStore.KeychainError.emptyKey` を投げる
    func saveAPIKey(_ key: String) async throws
    func deleteAPIKey() async throws
}

/// macOS の従来のキーチェーン（ログインキーチェーン）に、汎用パスワードとして保存する。
///
/// - データ保護キーチェーン（`kSecUseDataProtectionKeychain`）は keychain-access-groups とチームの署名が要るので使わない
/// - iCloud キーチェーンへの同期はしない（`kSecAttrSynchronizable` を付けない）
/// - キーチェーンの操作は、アクセス許可のダイアログが出ている間止まるので、メインスレッドでは行わない（`@concurrent`）
public struct KeychainStore: SecretStore {
    public enum KeychainError: Error, Equatable, Sendable {
        case emptyKey
        case unexpectedStatus(OSStatus)
    }

    /// アプリが使う既定の保存場所
    public static let defaultService = "com.example.LiveMinutes.openai"
    static let account = "openai-api-key"

    private let service: String

    /// - Parameter service: テストでは本番と別の名前を渡す
    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func hasAPIKey() async -> Bool {
        await Self.hasItem(service: service)
    }

    public func readAPIKey() async throws -> String {
        try await Self.read(service: service)
    }

    public func saveAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError.emptyKey }
        try await Self.save(trimmed, service: service)
    }

    public func deleteAPIKey() async throws {
        try await Self.delete(service: service)
    }

    // MARK: - キーチェーンの操作（メインスレッド以外で動かす）

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 属性だけを問い合わせる（値を読まないので、アクセス許可のダイアログを避けられる見込み）。
    @concurrent
    private static func hasItem(service: String) async -> Bool {
        var query = baseQuery(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @concurrent
    private static func read(service: String) async throws -> String {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                throw LLMError.apiKeyUnavailable
            }
            return key
        case errSecItemNotFound:
            throw LLMError.missingAPIKey
        default:
            // errSecUserCanceled、errSecAuthFailed、errSecInteractionNotAllowed など。
            throw LLMError.apiKeyUnavailable
        }
    }

    /// 消してから追加する（今のビルドのアクセス権で作り直すため）。
    @concurrent
    private static func save(_ key: String, service: String) async throws {
        let deleteStatus = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        var attributes = baseQuery(service: service)
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrLabel as String] = "LiveMinutes: OpenAI API キー"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    @concurrent
    private static func delete(service: String) async throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

extension KeychainStore.KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            "API キーを入力してください。"
        case .unexpectedStatus(let status):
            "キーチェーンに保存できませんでした（\(status)）。"
        }
    }
}

/// メモリ上に持つ `SecretStore`（テストとプレビュー用）。
public actor InMemorySecretStore: SecretStore {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func hasAPIKey() async -> Bool { key != nil }

    public func readAPIKey() async throws -> String {
        guard let key else { throw LLMError.missingAPIKey }
        return key
    }

    public func saveAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainStore.KeychainError.emptyKey }
        self.key = trimmed
    }

    public func deleteAPIKey() async throws {
        key = nil
    }
}
