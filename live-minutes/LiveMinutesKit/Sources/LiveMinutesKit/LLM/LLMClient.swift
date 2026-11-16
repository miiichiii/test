import Foundation

/// 構造化出力のリクエスト。
public struct StructuredOutputRequest: Sendable {
    public var model: String
    /// システムプロンプト（リクエストごとに変えない）
    public var instructions: String
    /// ユーザーメッセージ（入力JSONの文字列など）
    public var input: String
    /// スキーマの名前（`text.format.name`）
    public var schemaName: String
    /// JSON Schema の生のバイト列。キーの順序を保つため、組み直さずにそのままボディに入れる
    /// （構造化出力はスキーマのプロパティの順に出力を作るため）
    public var schema: Data
    /// 推論量（`reasoning.effort`）。nil なら送らない（対応していないモデルで 400 にならないように）
    public var reasoningEffort: String?
    /// 再試行を含むリクエスト全体の締め切り
    public var timeout: Duration

    public init(
        model: String,
        instructions: String,
        input: String,
        schemaName: String,
        schema: Data,
        reasoningEffort: String? = nil,
        timeout: Duration = .seconds(30)
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.schemaName = schemaName
        self.schema = schema
        self.reasoningEffort = reasoningEffort
        self.timeout = timeout
    }
}

/// テキストのストリーミングリクエスト。
public struct TextStreamRequest: Sendable {
    public var model: String
    public var instructions: String
    public var input: String
    public var reasoningEffort: String?
    /// 応答が始まるまで、または差分と差分の間に、何も届かない時間の上限（推論中は長く無通信になりうる）
    public var idleTimeout: Duration

    public init(
        model: String,
        instructions: String,
        input: String,
        reasoningEffort: String? = nil,
        idleTimeout: Duration = .seconds(180)
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.reasoningEffort = reasoningEffort
        self.idleTimeout = idleTimeout
    }
}

/// LLM の呼び出し（DESIGN.md §4.7）。ノートの更新と議事録の生成は、この protocol だけに依存する。
public protocol LLMClient: Sendable {
    /// 構造化出力を1回求め、出力の JSON（UTF-8 のバイト列）を返す。
    func structuredOutput(_ request: StructuredOutputRequest) async throws -> Data
    /// テキストをストリーミングで求め、届いた差分を順に返す。正常に完了したときだけ、エラーなしで終わる。
    ///
    /// 注意: 読む側の Task がキャンセルされると、`AsyncThrowingStream` はエラーなしで終わる（`for try await` が
    /// 正常に抜ける）。途中までの結果を完了したものとして扱わないよう、読み終えた後に `try Task.checkCancellation()` を呼ぶ。
    func streamText(_ request: TextStreamRequest) -> AsyncThrowingStream<String, any Error>
}

/// LLM の呼び出しの失敗。
///
/// 中身（`message` や拒否の文）には会議の内容や API キーの一部が含まれうるので、ログには `logSummary` だけを出す。
public enum LLMError: Error, Equatable, Sendable {
    /// API キーが保存されていない
    case missingAPIKey
    /// キーチェーンから API キーを読めない（アクセスを拒否された、など）
    case apiKeyUnavailable
    /// 401。キーが正しくない（応答の文はキーの一部を含むので持たない）
    case authentication
    /// 403。プロジェクトにモデルの利用権がない、地域の制限など
    case permissionDenied(message: String?)
    /// 429 のうち、残高や利用上限が足りない（再試行しない）
    case quotaExceeded
    /// 429。再試行しても空かなかった
    case rateLimited
    /// 5xx。再試行しても直らなかった
    case server(status: Int)
    /// 400・404 など。モデルIDの誤りやスキーマの不備。API の説明文を持つ
    case badRequest(status: Int, code: String?, message: String?)
    /// 締め切りまでに応答がなかった
    case timeout
    /// ネットワークにつながらない、通信が切れた
    case network
    /// モデルが応答を拒否した
    case refusal(String)
    /// 応答が途中で終わった（`incomplete_details.reason`）
    case incomplete(reason: String?)
    /// 応答の形が想定と違う、出力が JSON として読めない
    case invalidOutput
    /// API が失敗を返した（`status: failed` やストリーミングの error イベント）
    case failed(code: String?, message: String?)

    // MARK: ChatGPT のプランの利用枠（DESIGN.md §4.11）

    /// ChatGPT にログインしていない、またはログインし直しが必要
    case chatGPTSignInRequired
    /// ログインはしているが、プランの利用（`chatgpt.tokens.use.direct`）が許可されていない
    case chatGPTPlanNotGranted
    /// キーチェーンからログインの情報を読めない（アクセスを拒否された、など）
    case chatGPTCredentialUnavailable
    /// トークンを更新したのに、また 401 だった
    case chatGPTUnauthorized
    /// 設定の誤り（`chatpass_v2_*`、`subscription_sharing_route_not_supported`、`invalid_client`）
    case chatGPTRejected(code: String?)
    /// 使用量の上限（`subscription_sharing_usage_limit_exceeded`）。プランかアプリごとの上限
    case usageLimitReached
    /// 使用量を確かめられなかった（`subscription_sharing_usage_unavailable` など。一時的）
    case planUsageUnavailable
    /// プランの対象外（`subscription_sharing_user_not_eligible`）
    case planNotEligible(message: String?)
    /// プランの利用枠では使えないパラメータ（`subscription_sharing_unsupported_capability`）
    case unsupportedCapability(param: String?)

    /// ログ用の要約。会議の内容やキーを含まない値だけを出す。
    public var logSummary: String {
        switch self {
        case .missingAPIKey: "missingAPIKey"
        case .apiKeyUnavailable: "apiKeyUnavailable"
        case .authentication: "authentication"
        case .permissionDenied: "permissionDenied"
        case .quotaExceeded: "quotaExceeded"
        case .rateLimited: "rateLimited"
        case .server(let status): "server(\(status))"
        case .badRequest(let status, let code, _): "badRequest(\(status), code: \(code ?? "-"))"
        case .timeout: "timeout"
        case .network: "network"
        case .refusal: "refusal"
        case .incomplete(let reason): "incomplete(\(reason ?? "-"))"
        case .invalidOutput: "invalidOutput"
        case .failed(let code, _): "failed(code: \(code ?? "-"))"
        case .chatGPTSignInRequired: "chatGPTSignInRequired"
        case .chatGPTPlanNotGranted: "chatGPTPlanNotGranted"
        case .chatGPTCredentialUnavailable: "chatGPTCredentialUnavailable"
        case .chatGPTUnauthorized: "chatGPTUnauthorized"
        case .chatGPTRejected(let code): "chatGPTRejected(code: \(code ?? "-"))"
        case .usageLimitReached: "usageLimitReached"
        case .planUsageUnavailable: "planUsageUnavailable"
        case .planNotEligible: "planNotEligible"
        case .unsupportedCapability(let param): "unsupportedCapability(param: \(param ?? "-"))"
        }
    }

    /// ChatGPT のエラーコード（`subscription_sharing_*` など）を対応付ける。該当しなければ nil
    /// （DESIGN.md §4.11 のエラーの表。HTTP のエラー応答・`response.failed`・`error` イベントで共有する）
    static func chatGPTPlanError(code: String?, message: String?, param: String?) -> LLMError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            .usageLimitReached
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            .planUsageUnavailable
        case "subscription_sharing_user_not_eligible":
            .planNotEligible(message: message)
        case "subscription_sharing_unsupported_capability":
            .unsupportedCapability(param: param)
        case "subscription_sharing_invalid_user":
            .chatGPTUnauthorized
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context",
             "subscription_sharing_route_not_supported":
            .chatGPTRejected(code: code)
        default:
            nil
        }
    }
}

/// ChatGPT の使用量の画面（UI/UX guidelines の「Manage usage」のリンク先。DESIGN.md §8 #11）
public enum ChatGPTLinks {
    public static let usage: URL? = URL(string: "https://chatgpt.com/settings/usage")
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenAI の API キーが設定されていません。設定画面で入力してください。"
        case .apiKeyUnavailable:
            "キーチェーンから API キーを読めませんでした。アクセスを許可するか、設定画面でキーを保存し直してください。"
        case .authentication:
            "API キーが正しくありません（認証エラー）。設定画面でキーを確認してください。"
        case .permissionDenied(let message):
            withDetail("このキーではモデルを利用できません（権限エラー）。", message)
        case .quotaExceeded:
            "OpenAI の利用上限か残高が足りません。OpenAI の管理画面で請求設定を確認してください。"
        case .rateLimited:
            "リクエストが多すぎるため、OpenAI に断られました。しばらく待ってから試してください。"
        case .server(let status):
            "OpenAI のサーバーでエラーが起きました（\(status)）。しばらく待ってから試してください。"
        case .badRequest(_, let code, let message):
            if code == "model_not_found" {
                withDetail("指定したモデルIDが見つかりません。設定画面でモデルIDを確認してください。", message)
            } else {
                withDetail("リクエストが受け付けられませんでした。モデルIDなどの設定を確認してください。", message)
            }
        case .timeout:
            "OpenAI から時間内に応答がありませんでした。"
        case .network:
            "OpenAI に接続できませんでした。ネットワークを確認してください。"
        case .refusal:
            "モデルが応答を拒否しました。"
        case .incomplete(let reason):
            withDetail("応答が途中で終わりました。", reason)
        case .invalidOutput:
            "OpenAI の応答を読み取れませんでした。"
        case .failed(_, let message):
            withDetail("OpenAI での処理に失敗しました。", message)
        case .chatGPTSignInRequired:
            "ChatGPT へのログインが必要です。設定画面で「ChatGPT で続ける」からログインしてください。"
        case .chatGPTPlanNotGranted:
            "ChatGPT のプランの利用が許可されていません。もう一度ログインして許可するか、接続方法を API キーにしてください。"
        case .chatGPTCredentialUnavailable:
            "キーチェーンから ChatGPT のログイン情報を読めませんでした。アクセスを許可するか、ログインし直してください。"
        case .chatGPTUnauthorized:
            "ChatGPT のログインが受け付けられませんでした。再試行するか、設定画面でログインし直してください。"
        case .chatGPTRejected(let code):
            withDetail("ChatGPT のプランでの利用が受け付けられませんでした（設定の誤り）。", code)
        case .usageLimitReached:
            "ChatGPT の使用量の上限に達しました。プランかこのアプリの上限を、ChatGPT の設定（使用量）で確認してください。"
        case .planUsageUnavailable:
            "ChatGPT のプランの使用量を確認できませんでした。しばらく待ってから試してください。"
        case .planNotEligible(let message):
            withDetail("この ChatGPT のアカウントでは、プランの利用枠を使えません。", message)
        case .unsupportedCapability(let param):
            withDetail("ChatGPT のプランの利用枠では使えない指定が含まれていました。", param)
        }
    }

    private func withDetail(_ text: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return text }
        return "\(text)（\(detail)）"
    }
}
