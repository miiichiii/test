import Foundation

/// OpenAI への接続方法（DESIGN.md §4.11）。設定画面で選び、`UserDefaults` に保存する。
public enum AuthMethod: String, CaseIterable, Sendable {
    /// OpenAI の API キー（従量課金）
    case apiKey
    /// ChatGPT のプランの利用枠（Sign in with ChatGPT）
    case chatGPTPlan
}

/// リクエストに使う資格情報。値は文字列にしても出ない（ログや `print` に紛れ込まないように）。
public enum LLMCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case apiKey(String)
    case chatGPTPlan(accessToken: String)

    public var method: AuthMethod {
        switch self {
        case .apiKey: .apiKey
        case .chatGPTPlan: .chatGPTPlan
        }
    }

    /// `Authorization: Bearer` に入れる値
    var bearerValue: String {
        switch self {
        case .apiKey(let key): key
        case .chatGPTPlan(let token): token
        }
    }

    public var description: String {
        switch self {
        case .apiKey: "LLMCredential.apiKey(<redacted>)"
        case .chatGPTPlan: "LLMCredential.chatGPTPlan(<redacted>)"
        }
    }

    public var debugDescription: String { description }
}

/// `OpenAIResponsesClient` に資格情報を渡す。
public protocol CredentialProvider: Sendable {
    /// 今の資格情報を返す。ない場合は `LLMError`（`missingAPIKey`、`chatGPTSignInRequired` など）を投げる
    func credential() async throws -> LLMCredential
    /// 401 を受けたときに、失敗した資格情報を渡して呼ぶ。新しい資格情報で1回だけ送り直す価値があれば true
    func handleUnauthorized(_ used: LLMCredential) async -> Bool
}

/// API キーの資格情報。401 を受けたら持っているキーを捨てる（送り直しはしない）。
public struct APIKeyCredentialProvider: CredentialProvider {
    private let read: @Sendable () async throws -> String
    private let invalidate: @Sendable () async -> Void

    public init(
        read: @escaping @Sendable () async throws -> String,
        invalidate: @escaping @Sendable () async -> Void = {}
    ) {
        self.read = read
        self.invalidate = invalidate
    }

    public func credential() async throws -> LLMCredential {
        .apiKey(try await read())
    }

    public func handleUnauthorized(_ used: LLMCredential) async -> Bool {
        await invalidate()
        return false
    }
}

/// 設定の接続方法に従って、API キーか ChatGPT の資格情報を返す。接続方法はリクエストのたびに読む。
public struct CredentialRouter: CredentialProvider {
    private let method: @MainActor @Sendable () -> AuthMethod
    private let apiKey: any CredentialProvider
    private let chatGPT: any CredentialProvider

    /// - Parameter method: 今の接続方法（`AppSettings` は MainActor なので MainActor で読む）
    public init(
        method: @escaping @MainActor @Sendable () -> AuthMethod,
        apiKey: any CredentialProvider,
        chatGPT: any CredentialProvider
    ) {
        self.method = method
        self.apiKey = apiKey
        self.chatGPT = chatGPT
    }

    public func credential() async throws -> LLMCredential {
        switch await method() {
        case .apiKey: try await apiKey.credential()
        case .chatGPTPlan: try await chatGPT.credential()
        }
    }

    /// 送った時点の方式の担当に渡す（リクエストの途中で接続方法が変わっても取り違えないように）。
    public func handleUnauthorized(_ used: LLMCredential) async -> Bool {
        switch used.method {
        case .apiKey: await apiKey.handleUnauthorized(used)
        case .chatGPTPlan: await chatGPT.handleUnauthorized(used)
        }
    }
}
