import Foundation
import Network

/// ネットワークにつながったかを知らせる（Phase 6。オフラインの後に、ノートの送信をすぐに再開するため）。
public final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LiveMinutes.NetworkMonitor")
    /// つながっているか（変わったときだけ流す）
    public let availability: AsyncStream<Bool>

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        availability = stream
        monitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
