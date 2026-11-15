import Foundation
import os

/// OpenAI Responses API（`POST /v1/responses`）による `LLMClient`（DESIGN.md §4.7）。外部ライブラリは使わない。
///
/// - 応答を OpenAI 側に保存させないよう、`store: false` を必ず送る
/// - 429（利用上限の不足を除く）・5xx・通信エラーは、間隔を空けて最大2回まで再試行する。401・403・400・404 などは再試行しない
/// - 構造化出力は、再試行を含む全体に締め切りを設ける。ストリーミングは無通信の時間に上限を設ける
/// - API キーはリクエストのたびに読む。キーやリクエストの中身はログに出さない
public struct OpenAIResponsesClient: LLMClient {
    public typealias APIKeyProvider = @Sendable () async throws -> String
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// 再試行の最大回数（最初の1回を除く）
    static let maxRetries = 2
    /// Retry-After がこれより長ければ、待たずに失敗として返す（ライブ更新は次の周期で送り直すため）
    static let maxRetryAfter: TimeInterval = 5
    /// エラー応答の本文を読む上限
    static let maxErrorBodyBytes = 64 * 1024

    private let session: URLSession
    private let endpoint: URL
    private let apiKey: APIKeyProvider
    private let sleep: Sleep
    private let onAuthenticationFailure: (@Sendable () async -> Void)?

    private static let logger = Logger(subsystem: LiveMinutesInfo.logSubsystem, category: "LLM")

    /// 既定のエンドポイント `https://api.openai.com/v1/responses`
    public static var defaultEndpoint: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        components.path = "/v1/responses"
        return components.url ?? URL(filePath: "/")
    }

    /// 応答をディスクに残さないセッション。
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// - Parameters:
    ///   - session: テストでは URLProtocol のスタブを入れたセッションを渡す
    ///   - apiKey: API キーを返す。ない場合は `LLMError.missingAPIKey` などを投げる
    ///   - sleep: 再試行の待ち。テストでは待たない関数を渡す
    ///   - onAuthenticationFailure: 401 を受けたときに呼ぶ（持っているキーを捨てるため）
    public init(
        session: URLSession = OpenAIResponsesClient.makeSession(),
        endpoint: URL = OpenAIResponsesClient.defaultEndpoint,
        apiKey: @escaping APIKeyProvider,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        onAuthenticationFailure: (@Sendable () async -> Void)? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.sleep = sleep
        self.onAuthenticationFailure = onAuthenticationFailure
    }

    // MARK: - 構造化出力

    public func structuredOutput(_ request: StructuredOutputRequest) async throws -> Data {
        // キーチェーンの許可ダイアログを待つ時間を締め切りに含めないよう、先に読む。
        let key = try await apiKey()
        let urlRequest = makeURLRequest(
            body: try Self.structuredBody(request),
            key: key,
            // 締め切りより先に URLSession の無通信タイムアウトが来ないようにする。
            timeoutInterval: request.timeout.seconds + 5,
            streaming: false
        )
        return try await Self.withDeadline(request.timeout) {
            let data = try await self.send(urlRequest)
            return try Self.parseStructuredResponse(data)
        }
    }

    /// 再試行つきで送り、2xx の本文を返す。
    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let delay: Duration
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LLMError.invalidOutput }
                if (200..<300).contains(http.statusCode) {
                    return data
                }
                let error = Self.error(status: http.statusCode, body: data)
                if error == .authentication { await onAuthenticationFailure?() }
                guard attempt < Self.maxRetries, let wait = Self.retryDelay(for: error, attempt: attempt, http: http) else {
                    throw error
                }
                delay = wait
                Self.logger.notice("再試行する（\(attempt + 1)回目）: \(error.logSummary, privacy: .public)")
            } catch let error as URLError {
                // キャンセルは通信エラーとして再試行しない。
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                let mapped = Self.map(error)
                guard attempt < Self.maxRetries, Self.isTransient(error) else {
                    throw mapped
                }
                delay = Self.backoff(attempt: attempt)
                Self.logger.notice("通信エラーのため再試行する（\(attempt + 1)回目）: \(error.code.rawValue)")
            }
            attempt += 1
            try await sleep(delay)
        }
    }

    // MARK: - ストリーミング

    public func streamText(_ request: TextStreamRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(_ request: TextStreamRequest, yield: (String) -> Void) async throws {
        let key = try await apiKey()
        let urlRequest = makeURLRequest(
            body: try Self.streamBody(request),
            key: key,
            timeoutInterval: request.idleTimeout.seconds,
            streaming: true
        )
        var attempt = 0
        var hasYielded = false
        while true {
            try Task.checkCancellation()
            let delay: Duration
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { throw LLMError.invalidOutput }
                guard (200..<300).contains(http.statusCode) else {
                    // エラー応答は SSE ではなく JSON。上限つきで読む。
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count >= Self.maxErrorBodyBytes { break }
                    }
                    let error = Self.error(status: http.statusCode, body: body)
                    if error == .authentication { await onAuthenticationFailure?() }
                    guard attempt < Self.maxRetries, let wait = Self.retryDelay(for: error, attempt: attempt, http: http) else {
                        throw error
                    }
                    Self.logger.notice("再試行する（\(attempt + 1)回目）: \(error.logSummary, privacy: .public)")
                    attempt += 1
                    try await sleep(wait)
                    continue
                }
                var parser = StreamEventParser()
                // SSE の行の区切りは CR / LF だけ。`bytes.lines` は U+2028 などでも行を切るので使わず、0x0A で自前に分ける。
                var line = Data()
                for try await byte in bytes {
                    guard byte == 0x0A else {
                        line.append(byte)
                        continue
                    }
                    if line.last == 0x0D { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    line.removeAll(keepingCapacity: true)
                    switch try parser.consume(line: text) {
                    case .delta(let delta):
                        hasYielded = true
                        yield(delta)
                    case .completed:
                        return
                    case nil:
                        continue
                    }
                }
                // response.completed を受けずに終わった（途中で切れた）。
                throw LLMError.network
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                let mapped = Self.map(error)
                // 差分を渡し始めた後に再試行すると、同じ文が重複するので再試行しない。
                guard !hasYielded, attempt < Self.maxRetries, Self.isTransient(error) else {
                    throw mapped
                }
                delay = Self.backoff(attempt: attempt)
                Self.logger.notice("通信エラーのため再試行する（\(attempt + 1)回目）: \(error.code.rawValue)")
            }
            attempt += 1
            try await sleep(delay)
        }
    }

    // MARK: - リクエスト

    private func makeURLRequest(body: Data, key: String, timeoutInterval: TimeInterval, streaming: Bool) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// 構造化出力のボディ。スキーマは受け取ったバイト列をそのまま埋め込み、キーの順序を保つ。
    static func structuredBody(_ request: StructuredOutputRequest) throws -> Data {
        var body = Data("{".utf8)
        try appendCommonFields(to: &body, model: request.model, instructions: request.instructions,
                               input: request.input, reasoningEffort: request.reasoningEffort)
        body.append(Data(#","text":{"format":{"type":"json_schema","name":"#.utf8))
        body.append(try encode(request.schemaName))
        body.append(Data(#","strict":true,"schema":"#.utf8))
        body.append(request.schema)
        body.append(Data("}}}".utf8))
        return body
    }

    static func streamBody(_ request: TextStreamRequest) throws -> Data {
        var body = Data("{".utf8)
        try appendCommonFields(to: &body, model: request.model, instructions: request.instructions,
                               input: request.input, reasoningEffort: request.reasoningEffort)
        body.append(Data(#","stream":true}"#.utf8))
        return body
    }

    private static func appendCommonFields(
        to body: inout Data, model: String, instructions: String, input: String, reasoningEffort: String?
    ) throws {
        body.append(Data(#""model":"#.utf8))
        body.append(try encode(model))
        body.append(Data(#","instructions":"#.utf8))
        body.append(try encode(instructions))
        body.append(Data(#","input":"#.utf8))
        body.append(try encode(input))
        // 応答を OpenAI 側に保存させない。
        body.append(Data(#","store":false"#.utf8))
        if let reasoningEffort, !reasoningEffort.isEmpty {
            body.append(Data(#","reasoning":{"effort":"#.utf8))
            body.append(try encode(reasoningEffort))
            body.append(Data("}".utf8))
        }
    }

    private static func encode(_ string: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(string)
    }

    // MARK: - 応答

    /// 構造化出力の応答から、出力の JSON を取り出す。
    /// 状態 → 拒否 → 出力テキストの順に見る。推論の項目などは無視し、全 message の output_text をつなぐ。
    static func parseStructuredResponse(_ data: Data) throws -> Data {
        guard let response = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw LLMError.invalidOutput
        }
        try response.throwIfNotCompleted()
        var text = ""
        for item in response.output ?? [] where item.type == "message" {
            for part in item.content ?? [] {
                switch part.type {
                case "refusal":
                    throw LLMError.refusal(part.refusal ?? "")
                case "output_text":
                    text += part.text ?? ""
                default:
                    continue
                }
            }
        }
        let output = Data(text.utf8)
        guard !text.isEmpty, (try? JSONSerialization.jsonObject(with: output)) != nil else {
            throw LLMError.invalidOutput
        }
        return output
    }

    /// 2xx 以外の応答を `LLMError` にする。本文は `{"error": {"message", "type", "code", "param"}}` を想定する。
    static func error(status: Int, body: Data) -> LLMError {
        let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        switch status {
        case 401:
            // 応答の文にはキーの一部が含まれるので使わない。
            return .authentication
        case 403:
            return .permissionDenied(message: detail?.message)
        case 429:
            return detail?.code == "insufficient_quota" ? .quotaExceeded : .rateLimited
        case 500...599:
            return .server(status: status)
        default:
            return .badRequest(status: status, code: detail?.code, message: detail?.message)
        }
    }

    /// 再試行して直る見込みのある通信エラー。ネットワークにつながっていない、証明書の誤り、タイムアウトなどは含めない。
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse, .resourceUnavailable:
            true
        default:
            false
        }
    }

    static func map(_ error: URLError) -> LLMError {
        switch error.code {
        case .timedOut:
            return .timeout
        default:
            return .network
        }
    }

    /// 再試行するなら待つ時間を、しないなら nil を返す。
    static func retryDelay(for error: LLMError, attempt: Int, http: HTTPURLResponse) -> Duration? {
        switch error {
        case .rateLimited, .server:
            if let header = http.value(forHTTPHeaderField: "Retry-After") {
                guard let seconds = retryAfterSeconds(header), seconds <= maxRetryAfter else { return nil }
                return .milliseconds(Int(max(seconds, 0) * 1000))
            }
            return backoff(attempt: attempt)
        default:
            return nil
        }
    }

    static func backoff(attempt: Int) -> Duration {
        .seconds(attempt == 0 ? 1 : 2)
    }

    /// Retry-After の秒数（数値か HTTP 日付）。
    static func retryAfterSeconds(_ header: String, now: Date = Date()) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return date.timeIntervalSince(now)
    }

    /// 締め切りつきで実行する。締め切りに負けたときだけ `LLMError.timeout`、親のキャンセルは `CancellationError`。
    static func withDeadline<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: DeadlineOutcome<T>.self) { group in
            group.addTask { .value(try await operation()) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            switch first {
            case .value(let value):
                return value
            case .timedOut:
                throw LLMError.timeout
            }
        }
    }

    private enum DeadlineOutcome<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }
}

// MARK: - 応答の型

struct ErrorEnvelope: Decodable {
    let error: APIErrorDetail?
}

/// エラーの詳細。想定外の形（code が数値など）でも、読めるフィールドだけ読む。
struct APIErrorDetail: Decodable {
    let message: String?
    let type: String?
    let code: String?
    let param: String?

    enum CodingKeys: String, CodingKey {
        case message, type, code, param
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decode(String.self, forKey: .message)
        type = try? container.decode(String.self, forKey: .type)
        if let code = try? container.decode(String.self, forKey: .code) {
            self.code = code
        } else if let number = try? container.decode(Int.self, forKey: .code) {
            code = String(number)
        } else {
            code = nil
        }
        param = try? container.decode(String.self, forKey: .param)
    }
}

struct ResponseBody: Decodable {
    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    /// 出力の項目。message 以外（推論など）の形は問わないので、読めなければ空にする。
    struct OutputItem: Decodable {
        let type: String
        let content: [ContentPart]?

        enum CodingKeys: String, CodingKey {
            case type, content
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            content = try? container.decode([ContentPart].self, forKey: .content)
        }
    }

    struct ContentPart: Decodable {
        let type: String
        let text: String?
        let refusal: String?

        enum CodingKeys: String, CodingKey {
            case type, text, refusal
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            text = try? container.decode(String.self, forKey: .text)
            refusal = try? container.decode(String.self, forKey: .refusal)
        }
    }

    let status: String?
    let error: APIErrorDetail?
    let incompleteDetails: IncompleteDetails?
    let output: [OutputItem]?

    enum CodingKeys: String, CodingKey {
        case status, error, output
        case incompleteDetails = "incomplete_details"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decode(String.self, forKey: .status)
        error = try? container.decode(APIErrorDetail.self, forKey: .error)
        incompleteDetails = try? container.decode(IncompleteDetails.self, forKey: .incompleteDetails)
        output = try? container.decode([OutputItem].self, forKey: .output)
    }

    func throwIfNotCompleted() throws {
        switch status {
        case "failed":
            throw LLMError.failed(code: error?.code, message: error?.message)
        case "incomplete":
            throw LLMError.incomplete(reason: incompleteDetails?.reason)
        default:
            if let error {
                throw LLMError.failed(code: error.code, message: error.message)
            }
        }
    }
}

/// SSE の data 行を読み、テキストの差分と完了を取り出す。
struct StreamEventParser {
    enum Output: Equatable {
        case delta(String)
        case completed
    }

    /// イベント。type 以外は読めるものだけ読む（response の形が想定と違っても、完了を見逃さないため）。
    private struct Event: Decodable {
        let type: String?
        let delta: String?
        let code: String?
        let message: String?
        let response: ResponseBody?
        let error: APIErrorDetail?

        enum CodingKeys: String, CodingKey {
            case type, delta, code, message, response, error
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decode(String.self, forKey: .type)
            delta = try? container.decode(String.self, forKey: .delta)
            code = try? container.decode(String.self, forKey: .code)
            message = try? container.decode(String.self, forKey: .message)
            response = try? container.decode(ResponseBody.self, forKey: .response)
            error = try? container.decode(APIErrorDetail.self, forKey: .error)
        }
    }

    private var refusal = ""

    /// 1行を読む。data 行以外（event 行・コメント）は nil。失敗のイベントは投げる。
    mutating func consume(line: String) throws -> Output? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return nil
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else {
            return nil
        }
        // 公式 SDK と同じく、error キーを持つデータは失敗として扱う。
        if event.type == nil, let error = event.error {
            throw LLMError.failed(code: error.code, message: error.message)
        }
        switch event.type {
        case "response.output_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return nil }
            return .delta(delta)
        case "response.refusal.delta":
            refusal += event.delta ?? ""
            return nil
        case "response.completed":
            if !refusal.isEmpty {
                throw LLMError.refusal(refusal)
            }
            try event.response?.throwIfNotCompleted()
            return .completed
        case "response.failed":
            throw LLMError.failed(code: event.response?.error?.code, message: event.response?.error?.message)
        case "response.incomplete":
            throw LLMError.incomplete(reason: event.response?.incompleteDetails?.reason)
        case "error":
            throw LLMError.failed(code: event.code, message: event.message)
        default:
            return nil
        }
    }
}

extension Duration {
    /// 秒数（小数）
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
