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
        }
    }
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
        }
    }

    private func withDetail(_ text: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return text }
        return "\(text)（\(detail)）"
    }
}
