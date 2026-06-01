import Foundation
import Network
import Combine

@MainActor
final class ProxyServer: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt16 = 8888
    @Published var localIP: String = "—"
    @Published var cellularIP: String = "—"
    @Published var tailscaleIP: String = "—"
    @Published var activeConnections: Int = 0
    @Published var bytesUp: UInt64 = 0
    @Published var bytesDown: UInt64 = 0
    @Published var log: [String] = []

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "proxy.listener", qos: .userInitiated)
    private var ipRefreshTimer: Timer?

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = false

            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                Task { @MainActor in
                    self.activeConnections += 1
                }
                HTTPProxyHandler.handle(client: conn, server: self, queue: self.queue)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.refreshIPs()
                        self.append("Listening on port \(self.port)")
                        self.ipRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                            Task { @MainActor in self.refreshIPs() }
                        }
                    case .failed(let err):
                        self.append("Listener failed: \(err)")
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener.start(queue: queue)
        } catch {
            append("Start error: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        ipRefreshTimer?.invalidate()
        ipRefreshTimer = nil
    }

    nonisolated func recordUp(_ n: Int) {
        Task { @MainActor in self.bytesUp &+= UInt64(n) }
    }
    nonisolated func recordDown(_ n: Int) {
        Task { @MainActor in self.bytesDown &+= UInt64(n) }
    }
    nonisolated func connectionClosed() {
        Task { @MainActor in
            if self.activeConnections > 0 { self.activeConnections -= 1 }
        }
    }
    nonisolated func logLine(_ s: String) {
        Task { @MainActor in self.append(s) }
    }

    private func append(_ s: String) {
        let ts = Self.timeFormatter.string(from: Date())
        log.append("\(ts)  \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func refreshIPs() {
        localIP = NetworkInterface.address(for: .wifi) ?? "—"
        cellularIP = NetworkInterface.address(for: .cellular) ?? "—"
        tailscaleIP = NetworkInterface.tailscaleAddress() ?? "—"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
