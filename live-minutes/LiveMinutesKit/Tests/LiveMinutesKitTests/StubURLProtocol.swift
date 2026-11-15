import Foundation
import Synchronization

/// テスト用の URLProtocol。実際の OpenAI API には接続しない。
///
/// テストごとに別の URL（`https://stub.invalid/<UUID>/v1/responses`）を使い、URL ごとに応答の決め方と
/// 届いたリクエストを記録する。並列に走るテスト同士で混ざらない。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // @unchecked の理由: 可変の状態は isStopped だけで、Mutex で守る。それ以外は URLProtocol の仕組みが
    // 1つのスレッドから呼ぶ（startLoading / stopLoading）。

    enum Stub: Sendable {
        /// HTTP 応答。本文は chunks を順に渡す。failure を指定すると、本文を渡してから failureDelay 秒後に通信エラーで終える
        case http(
            status: Int,
            headers: [String: String] = [:],
            chunks: [Data],
            failure: URLError.Code? = nil,
            failureDelay: TimeInterval = 0,
            delay: TimeInterval = 0
        )
        /// 応答なしで通信エラー
        case error(URLError.Code)

        static func json(_ status: Int, _ body: String, headers: [String: String] = [:], delay: TimeInterval = 0) -> Stub {
            .http(status: status, headers: headers, chunks: [Data(body.utf8)], delay: delay)
        }
    }

    struct RecordedRequest: Sendable {
        let headers: [String: String]
        let body: Data

        var bodyString: String { String(data: body, encoding: .utf8) ?? "" }

        var bodyJSON: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    /// 何回目のリクエスト（0始まり）か、から応答を決める
    typealias Handler = @Sendable (_ attempt: Int) -> Stub

    private struct Entry {
        let handler: Handler
        var requests: [RecordedRequest] = []
    }

    private static let entries = Mutex<[String: Entry]>([:])
    private let isStopped = Mutex(false)

    /// 新しい URL を用意して応答の決め方を登録する。
    static func register(_ handler: @escaping Handler) -> URL {
        let url = URL(string: "https://stub.invalid/\(UUID().uuidString)/v1/responses")!
        entries.withLock { $0[url.absoluteString] = Entry(handler: handler) }
        return url
    }

    static func requests(for url: URL) -> [RecordedRequest] {
        entries.withLock { $0[url.absoluteString]?.requests ?? [] }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        // URLProtocol の中では、ボディは httpBody ではなく httpBodyStream に移っている。
        let recorded = RecordedRequest(headers: request.allHTTPHeaderFields ?? [:], body: Self.readBody(request))
        let stub: Stub? = Self.entries.withLock { entries in
            guard var entry = entries[key] else { return nil }
            let attempt = entry.requests.count
            entry.requests.append(recorded)
            entries[key] = entry
            return entry.handler(attempt)
        }
        guard let stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch stub {
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let headers, let chunks, let failure, let failureDelay, let delay):
            let deliver: @Sendable () -> Void = { [self] in
                guard !isStopped.withLock({ $0 }) else { return }
                // 実際のサーバーと同じく Content-Type を付ける。付けないと URLSession が中身の判定のために
                // 先頭（最大512バイト）を溜め、ストリーミングの差分がすぐに届かなくなる。
                var headers = headers
                if headers["Content-Type"] == nil {
                    let isStream = chunks.first.map { $0.starts(with: Data("data:".utf8)) || $0.starts(with: Data("event:".utf8)) } ?? false
                    headers["Content-Type"] = isStream ? "text/event-stream" : "application/json"
                }
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in chunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
                if let failure {
                    if failureDelay > 0 {
                        DispatchQueue.global().asyncAfter(deadline: .now() + failureDelay) { [self] in
                            guard !isStopped.withLock({ $0 }) else { return }
                            client?.urlProtocol(self, didFailWithError: URLError(failure))
                        }
                    } else {
                        client?.urlProtocol(self, didFailWithError: URLError(failure))
                    }
                } else {
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { deliver() }
            } else {
                deliver()
            }
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
