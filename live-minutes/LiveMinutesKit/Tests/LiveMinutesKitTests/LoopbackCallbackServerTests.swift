import Foundation
import Network
import Synchronization
import Testing
@testable import LiveMinutesKit

/// ログインのコールバックの待ち受けのテスト。実際に `127.0.0.1` へ TCP でつなぐ（外部には接続しない）。
@Suite("ログインのコールバックの待ち受け")
struct LoopbackCallbackServerTests {
    /// 生の TCP で要求を送り、応答を全部読む。
    /// - Parameters:
    ///   - chunks: 順に送るバイト列（間を空けて送ると、1回の受信に収まらない要求になる）
    static func rawRequest(port: UInt16, chunks: [Data], gap: TimeInterval = 0.05) async throws -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test.raw")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { state in
                let shouldResume: Bool
                switch state {
                case .ready, .failed, .cancelled: shouldResume = resumed.withLock { value in defer { value = true }; return !value }
                default: shouldResume = false
                }
                guard shouldResume else { return }
                if case .failed(let error) = state { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            connection.start(queue: queue)
        }
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(gap)) }
            await withCheckedContinuation { continuation in
                connection.send(content: chunk, completion: .contentProcessed { _ in continuation.resume() })
            }
        }
        var response = Data()
        while true {
            let (data, isComplete): (Data?, Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data { response.append(data) }
            if isComplete || data == nil { break }
        }
        connection.cancel()
        return String(decoding: response, as: UTF8.self)
    }

    static func get(_ target: String) -> Data {
        Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    }

    private func startServer(timeout: TimeInterval = 10, connectionTimeout: TimeInterval = 5) async throws -> LoopbackCallbackServer {
        try await LoopbackCallbackServer.start(preferredPort: nil, timeout: timeout, connectionTimeout: connectionTimeout) { parameters in
            parameters["state"] == "good" ? .accept : .reject
        }
    }

    @Test("127.0.0.1 で待ち受け、redirect_uri は http://127.0.0.1:<ポート>/auth/callback")
    func redirectURI() async throws {
        let server = try await startServer()
        defer { server.stop() }
        #expect(server.port > 0)
        #expect(server.redirectURI == "http://127.0.0.1:\(server.port)/auth/callback")
    }

    @Test("決めたパス以外は 404、GET 以外は 405、大きすぎる要求は 400 を返し、待ち続ける")
    func rejectsOtherRequests() async throws {
        let server = try await startServer()
        defer { server.stop() }

        #expect(try await Self.rawRequest(port: server.port, chunks: [Self.get("/favicon.ico")]).hasPrefix("HTTP/1.1 404"))
        #expect(try await Self.rawRequest(port: server.port, chunks: [Data("POST /auth/callback HTTP/1.1\r\n\r\n".utf8)]).hasPrefix("HTTP/1.1 405"))
        let huge = Data("GET /auth/callback?x=\(String(repeating: "a", count: 20_000))".utf8)
        #expect(try await Self.rawRequest(port: server.port, chunks: [huge]).hasPrefix("HTTP/1.1 400"))
        #expect(try await Self.rawRequest(port: server.port, chunks: [Self.get("/auth/callback?state=bad&code=x")]).hasPrefix("HTTP/1.1 400"))

        // それでもまだ正しいコールバックを受け取れる。
        let response = try await Self.rawRequest(port: server.port, chunks: [Self.get("/auth/callback?state=good&code=c%2B1")])
        #expect(response.hasPrefix("HTTP/1.1 302"))
        #expect(response.contains("Location: /auth/done"))
        #expect(response.contains("Cache-Control: no-store"))
        let parameters = try await server.waitForCallback()
        #expect(parameters["code"] == "c+1")
    }

    @Test("分割して届く要求も読める")
    func splitRequest() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let request = Self.get("/auth/callback?state=good&code=abc")
        let middle = request.count / 2
        let response = try await Self.rawRequest(port: server.port, chunks: [request.prefix(middle), request.suffix(from: middle)])
        #expect(response.hasPrefix("HTTP/1.1 302"))
        #expect(try await server.waitForCallback()["code"] == "abc")
    }

    @Test("何も送らない接続があっても、ほかの要求を受け付ける")
    func idleConnectionDoesNotBlock() async throws {
        let server = try await startServer(connectionTimeout: 1)
        defer { server.stop() }
        // 何も送らずに切らない接続（ブラウザが先に張るもの）
        let idle = Task { try? await Self.rawRequest(port: server.port, chunks: []) }
        try await Task.sleep(for: .milliseconds(50))
        let response = try await Self.rawRequest(port: server.port, chunks: [Self.get("/auth/callback?state=good&code=z")])
        #expect(response.hasPrefix("HTTP/1.1 302"))
        #expect(try await server.waitForCallback()["code"] == "z")
        // 何も送らない接続は、接続ごとの上限で打ち切られる。
        _ = await idle.value
    }

    @Test("完了のページは 200 で、コードを含まない")
    func donePage() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let response = try await Self.rawRequest(port: server.port, chunks: [Self.get("/auth/done")])
        #expect(response.hasPrefix("HTTP/1.1 200"))
        // この後の交換や検証が失敗することもあるので、成功とは書かない。
        #expect(response.contains("手続きが終わりました"))
        #expect(!response.contains("ログインしました"))
    }

    @Test("希望のポートが使用中なら、OS に選ばせたポートで待ち受ける")
    func portFallback() async throws {
        let first = try await startServer()
        defer { first.stop() }
        let second = try await LoopbackCallbackServer.start(preferredPort: first.port) { _ in .accept }
        defer { second.stop() }
        #expect(second.port != first.port)
        #expect(second.port > 0)
        let response = try await Self.rawRequest(port: second.port, chunks: [Self.get("/auth/callback?state=x&code=y")])
        #expect(response.hasPrefix("HTTP/1.1 302"))
    }

    @Test("時間内にコールバックが来なければ timedOut、キャンセルすれば CancellationError")
    func timeoutAndCancel() async throws {
        let timingOut = try await startServer(timeout: 0.2)
        defer { timingOut.stop() }
        await #expect(throws: LoopbackCallbackServer.ServerError.timedOut) { try await timingOut.waitForCallback() }

        let cancelled = try await startServer()
        defer { cancelled.stop() }
        let waiting = Task { try await cancelled.waitForCallback() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
