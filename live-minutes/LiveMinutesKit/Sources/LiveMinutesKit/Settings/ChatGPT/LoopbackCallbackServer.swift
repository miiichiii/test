import Foundation
import Network
import Synchronization

/// ChatGPT のログインのコールバックを `127.0.0.1` で1回だけ受ける（DESIGN.md §4.11）。
///
/// - `127.0.0.1` だけに結び付ける（`::1` や全インターフェースには結び付けない）
/// - 希望のポート（1455）が使えなければ、OS に選ばせたポートで待ち受ける
/// - HTTP は要求行だけを読む最小限の実装。接続ごとに並行に処理し、接続ごとに数秒で打ち切る
/// - コールバックの検証（`state` など）は `validate` に任せる。合わなければ 400 を返して待ち続ける
///   （ほかのページやプロセスも `127.0.0.1` に要求を送れるので、それでログインを失敗にしないため）
/// - 受け取ったら、コードを含まないパスへ 302 で移す（アドレスバーと履歴にコードを残さないため）
final class LoopbackCallbackServer: Sendable {
    enum Decision: Sendable {
        /// 受け取る（302 で完了のページへ移す）
        case accept
        /// 受け取らない（400 を返して待ち続ける）
        case reject
    }

    enum ServerError: Error, Equatable, Sendable {
        /// 待ち受けを始められない
        case cannotListen
        /// 時間内にコールバックが来なかった
        case timedOut
    }

    static let callbackPath = "/auth/callback"
    static let donePath = "/auth/done"
    /// 要求の上限（これを超えたら打ち切る）
    static let maxRequestBytes = 16 * 1024

    private let listener: NWListener
    private let queue: DispatchQueue
    private let validate: @Sendable ([String: String]) -> Decision
    private let connectionTimeout: TimeInterval
    private let state = Mutex(State())

    private struct State {
        var continuation: CheckedContinuation<[String: String], any Error>?
        var pending: Result<[String: String], any Error>?
        var accepted = false
        var finished = false
    }

    /// 待ち受けているポート
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    deinit {
        listener.cancel()
    }

    var redirectURI: String { "http://127.0.0.1:\(port)\(Self.callbackPath)" }

    private init(
        listener: NWListener,
        queue: DispatchQueue,
        connectionTimeout: TimeInterval,
        validate: @escaping @Sendable ([String: String]) -> Decision
    ) {
        self.listener = listener
        self.queue = queue
        self.connectionTimeout = connectionTimeout
        self.validate = validate
    }

    /// 待ち受けを始める。準備ができてから返る。
    /// - Parameters:
    ///   - preferredPort: 先に試すポート。nil なら OS に選ばせる（テストでは nil）
    ///   - timeout: コールバックを待つ上限
    static func start(
        preferredPort: UInt16?,
        timeout: TimeInterval = 300,
        connectionTimeout: TimeInterval = 5,
        validate: @escaping @Sendable ([String: String]) -> Decision
    ) async throws -> LoopbackCallbackServer {
        if let preferredPort {
            if let server = try? await make(port: preferredPort, timeout: timeout, connectionTimeout: connectionTimeout, validate: validate) {
                return server
            }
        }
        return try await make(port: nil, timeout: timeout, connectionTimeout: connectionTimeout, validate: validate)
    }

    private static func make(
        port: UInt16?,
        timeout: TimeInterval,
        connectionTimeout: TimeInterval,
        validate: @escaping @Sendable ([String: String]) -> Decision
    ) async throws -> LoopbackCallbackServer {
        let parameters = NWParameters.tcp
        let endpointPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.cannotListen
        }
        let queue = DispatchQueue(label: "LiveMinutes.LoopbackCallbackServer")
        let server = LoopbackCallbackServer(listener: listener, queue: queue, connectionTimeout: connectionTimeout, validate: validate)
        try await server.waitUntilReady()
        // コールバックを待つ上限。
        queue.asyncAfter(deadline: .now() + timeout) { [server] in
            server.finish(.failure(ServerError.timedOut))
        }
        return server
    }

    private func waitUntilReady() async throws {
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resume: @Sendable (Result<Void, any Error>) -> Void = { result in
                guard resumed.withLock({ value in
                    defer { value = true }
                    return !value
                }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    resume(.success(()))
                case .waiting, .failed:
                    // ポートが使用中のときは、失敗ではなく待ちの状態になることがある。どちらでも諦める。
                    self?.listener.cancel()
                    resume(.failure(ServerError.cannotListen))
                    self?.finish(.failure(ServerError.cannotListen))
                case .cancelled:
                    resume(.failure(ServerError.cannotListen))
                    self?.finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// コールバックを待ち、クエリのパラメータを返す。キャンセルされたら `CancellationError`。
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending: Result<[String: String], any Error>? = state.withLock { state in
                    if let pending = state.pending {
                        state.pending = nil
                        return pending
                    }
                    state.continuation = continuation
                    return nil
                }
                if let pending { continuation.resume(with: pending) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// 待ち受けをやめる。
    /// - Parameter delay: 完了のページを返し終えるまで、少し待ってから閉じる
    func stop(after delay: TimeInterval = 0) {
        finish(.failure(CancellationError()))
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay) { [listener] in listener.cancel() }
        } else {
            listener.cancel()
        }
    }

    /// 結果を1回だけ渡す。待っている側がいなければ取っておく。
    private func finish(_ result: Result<[String: String], any Error>) {
        let continuation: CheckedContinuation<[String: String], any Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.pending = result
            return nil
        }
        continuation?.resume(with: result)
    }

    // MARK: - 接続

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // 何も送らない接続（ブラウザが先に張るもの）で受け付けが詰まらないよう、接続ごとに打ち切る。
        queue.asyncAfter(deadline: .now() + connectionTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if buffer.count > Self.maxRequestBytes {
                self.send(status: "400 Bad Request", body: Self.page("要求が大きすぎます。"), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", body: Self.page("要求を読めませんでした。"), on: connection)
            return
        }
        guard parts[0] == "GET" else {
            send(status: "405 Method Not Allowed", body: Self.page("この方法の要求は受け付けません。"), on: connection)
            return
        }
        guard let components = URLComponents(string: String(parts[1])) else {
            send(status: "400 Bad Request", body: Self.page("要求を読めませんでした。"), on: connection)
            return
        }
        switch components.path {
        case Self.donePath:
            // この後の交換や検証が失敗することもあるので、成功とは書かない。
            send(status: "200 OK", body: Self.page("ブラウザでの手続きが終わりました。このタブを閉じて、LiveMinutes で結果を確認してください。"), on: connection)
        case Self.callbackPath:
            var parameters: [String: String] = [:]
            for item in components.queryItems ?? [] where parameters[item.name] == nil {
                parameters[item.name] = item.value ?? ""
            }
            let alreadyAccepted = state.withLock { $0.accepted }
            if alreadyAccepted {
                redirectToDone(on: connection)
                return
            }
            switch validate(parameters) {
            case .accept:
                state.withLock { $0.accepted = true }
                finish(.success(parameters))
                redirectToDone(on: connection)
            case .reject:
                send(status: "400 Bad Request", body: Self.page("このログインの要求は、LiveMinutes が始めたものではありません。"), on: connection)
            }
        default:
            send(status: "404 Not Found", body: Self.page("見つかりません。"), on: connection)
        }
    }

    private func redirectToDone(on connection: NWConnection) {
        send(status: "302 Found", body: Data(), extraHeaders: ["Location: \(Self.donePath)"], on: connection)
    }

    private func send(status: String, body: Data, extraHeaders: [String] = [], on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for header in extraHeaders { head += "\(header)\r\n" }
        head += "\r\n"
        // 送り終わってから閉じる（先に閉じるとブラウザに接続のリセットが出る）。
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(_ message: String) -> Data {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><title>LiveMinutes</title>
        <style>body{font-family:-apple-system,sans-serif;margin:4em auto;max-width:32em;padding:0 1em;line-height:1.6}</style>
        </head><body><h1>LiveMinutes</h1><p>\(escaped)</p></body></html>
        """
        return Data(html.utf8)
    }
}
