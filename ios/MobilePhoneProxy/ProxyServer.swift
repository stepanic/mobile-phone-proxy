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
    @Published var publicIP: String = "—"
    @Published var publicIPCheckedAt: Date?
    @Published var isCheckingPublicIP = false
    @Published var keepAliveEnabled: Bool = false

    private let keepAlive = BackgroundAudioKeepAlive()
    @Published var activeConnections: Int = 0
    @Published var bytesUp: UInt64 = 0
    @Published var bytesDown: UInt64 = 0
    @Published var log: [String] = []

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "proxy.listener", qos: .userInitiated)
    private var ipRefreshTimer: Timer?
    private var publicIPTimer: Timer?
    private let lookupQueue = DispatchQueue(label: "proxy.publicip")

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
                        self.updateKeepAlive()
                        self.append("Listening on port \(self.port)")
                        self.ipRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                            Task { @MainActor in self.refreshIPs() }
                        }
                        self.refreshPublicIP()
                        self.publicIPTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                            Task { @MainActor in self.refreshPublicIP() }
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
        publicIPTimer?.invalidate()
        publicIPTimer = nil
        keepAlive.stop()
    }

    /// Starts/stops the silent-audio background keepalive to match current state.
    /// Call after the listener becomes ready, after stop, and when the toggle flips.
    func updateKeepAlive() {
        keepAlive.onLog = { [weak self] line in self?.logLine(line) }
        if isRunning && keepAliveEnabled {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
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
        let newCellular = NetworkInterface.address(for: .cellular) ?? "—"
        if newCellular != cellularIP {
            // A new carrier-internal address (e.g. after airplane mode) is the
            // moment the CGNAT public address may have changed too — re-check now
            // instead of waiting for the 30 s timer.
            if cellularIP != "—" || newCellular != "—" {
                append("Cellular IP \(cellularIP) → \(newCellular)")
            }
            cellularIP = newCellular
            if isRunning, newCellular != "—" { refreshPublicIP() }
        }
        tailscaleIP = NetworkInterface.tailscaleAddress() ?? "—"
    }

    /// Asks an external service for the public (post-CGNAT) address over cellular.
    func refreshPublicIP() {
        guard !isCheckingPublicIP else { return }
        isCheckingPublicIP = true
        PublicIP.fetch(queue: lookupQueue) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCheckingPublicIP = false
                switch result {
                case .success(let ip):
                    if ip != self.publicIP {
                        self.append("Public IP \(self.publicIP) → \(ip)")
                        self.publicIP = ip
                    }
                    self.publicIPCheckedAt = Date()
                case .failure(let error):
                    self.append("Public IP lookup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
