import Foundation
import Network
import Combine
import UIKit

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
    @Published var guidedAccess = UIAccessibility.isGuidedAccessEnabled
    /// Set while the "Rotate IP" shortcut is believed to be running.
    @Published var rotateStartedAt: Date?

    @Published var isPaired = RotateAuth.isPaired
    @Published var pairingOpenUntil: Date?
    @Published var lastRotateCommand: String?
    @Published var relayState = "off"

    private let relay = RelayClient()
    /// Relay job being executed, reported back once the new public IP is known.
    private var relayJob: (id: String, oldIP: String, awaitingIP: Bool)?
    private var relayReportedIP = ""

    /// The live instance, for App Intents (they run in-process but outside SwiftUI).
    static weak var current: ProxyServer?

    init() {
        Self.current = self
    }

    /// Name of the user-created Shortcut: Airplane ON → Wait 61 s → Airplane OFF.
    static let rotateShortcutName = "Rotate IP"

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
                        self.startRelay()
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
        relay.stop()
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
            if isRunning, newCellular != "—" {
                refreshPublicIP()
                relay.reconnectNow()
            }
        }
        tailscaleIP = NetworkInterface.tailscaleAddress() ?? "—"
        guidedAccess = UIAccessibility.isGuidedAccessEnabled
        if let until = pairingOpenUntil, until <= Date() { pairingOpenUntil = nil }
    }

    // MARK: - Control endpoint (GET /__status, /__log, /__rotate, /__pair)

    func handleControl(path: String) -> (status: String, json: String) {
        switch path {
        case "/__status":
            return ("200 OK", statusJSON())
        case "/__log":
            return ("200 OK", logJSON())
        case "/__rotate":
            return requestRotate()
        case "/__pair":
            return pair()
        #if targetEnvironment(simulator)
        case "/__open-pairing":
            // Simulator-only stand-in for tapping "Pair Mac".
            openPairingWindow()
            return ("200 OK", #"{"ok":true}"#)
        case let p where p.hasPrefix("/__callback/"):
            // Simulator-only stand-in for the shortcut's x-success / x-error
            // (the simulator has no "Rotate IP" shortcut, and simctl openurl
            // prompts before opening the app).
            handleCallback(URL(string: "mobilephoneproxy://" + p.dropFirst("/__callback/".count))!)
            return ("200 OK", #"{"ok":true}"#)
        case let p where p.hasPrefix("/__verify/"):
            // Simulator-only hook to test Mac-side signing against CryptoKit.
            let msg = String(p.dropFirst("/__verify/".count)).removingPercentEncoding ?? ""
            let v = RotateAuth.verify(msg)
            return ("200 OK", "{\"verdict\":\"\(v.description)\"}")
        #endif
        default:
            return ("404 Not Found", #"{"error":"unknown path"}"#)
        }
    }

    private func statusJSON(extra: [String: Any] = [:]) -> String {
        var d: [String: Any] = [
            "publicIP": publicIP,
            "cellularIP": cellularIP,
            "tailscaleIP": tailscaleIP,
            "wifiIP": localIP,
            "appActive": UIApplication.shared.applicationState == .active,
            "guidedAccess": UIAccessibility.isGuidedAccessEnabled,
            "rotating": rotateStartedAt != nil,
            "paired": RotateAuth.isPaired,
        ]
        if let at = publicIPCheckedAt { d["publicIPCheckedAt"] = ISO8601DateFormatter().string(from: at) }
        if let last = lastRotateCommand { d["lastRotateCommand"] = last }
        d.merge(extra) { _, new in new }
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// In-memory app log plus the persistent App Intent record (see IntentEventLog).
    private func logJSON() -> String {
        let d: [String: Any] = ["lines": log, "intentEvents": IntentEventLog.events]
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// iOS gives apps no API to toggle Airplane Mode, but Shortcuts has a
    /// "Set Airplane Mode" action. We launch the user's shortcut by URL; the
    /// x-success/x-error callbacks bring this app back to the foreground.
    /// Opening another app only works while we are the foreground app.
    private func requestRotate() -> (status: String, json: String) {
        if let started = rotateStartedAt, Date().timeIntervalSince(started) < 180 {
            return ("409 Conflict", statusJSON(extra: ["error": "rotation already in progress"]))
        }
        guard UIApplication.shared.applicationState == .active else {
            return ("409 Conflict", statusJSON(extra: ["error": "app is not in the foreground; iOS only lets the foreground app open Shortcuts"]))
        }
        var c = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        c.queryItems = [
            URLQueryItem(name: "name", value: Self.rotateShortcutName),
            URLQueryItem(name: "x-success", value: "mobilephoneproxy://rotate-done"),
            URLQueryItem(name: "x-cancel", value: "mobilephoneproxy://rotate-cancel"),
            URLQueryItem(name: "x-error", value: "mobilephoneproxy://rotate-error"),
        ]
        guard let url = c.url else { return ("500 Internal Server Error", #"{"error":"bad url"}"#) }
        rotateStartedAt = Date()
        append("Rotate requested — opening shortcut \"\(Self.rotateShortcutName)\" (public IP \(publicIP))")
        // Delay so the HTTP 202 reaches the Mac before airplane mode cuts the link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            UIApplication.shared.open(url) { [weak self] ok in
                guard let self, !ok else { return }
                self.rotateStartedAt = nil
                self.append("Rotate failed: iOS refused to open Shortcuts (Guided or Assistive Access on?)")
                self.finishRelayJob(ok: false, detail: "iOS refused to open Shortcuts (Guided or Assistive Access on?)")
            }
        }
        return ("202 Accepted", statusJSON(extra: ["started": true]))
    }

    // MARK: - iMessage rotate command pairing

    /// Opens a short window during which GET /__pair hands the HMAC secret to
    /// the Mac. Requiring a tap on the phone keeps other tailnet devices from
    /// silently fetching it.
    func openPairingWindow() {
        pairingOpenUntil = Date().addingTimeInterval(120)
        append("Pairing window open for 2 min — run: macos/rotate-ip.sh --pair")
    }

    func unpair() {
        RotateAuth.unpair()
        isPaired = false
        relay.stop()
        append("Unpaired — signed rotate commands now rejected")
    }

    private func pair() -> (status: String, json: String) {
        guard let until = pairingOpenUntil, until > Date() else {
            return ("403 Forbidden", #"{"error":"pairing window closed — tap 'Pair Mac' in the app"}"#)
        }
        let secret = RotateAuth.secretForPairing()
        pairingOpenUntil = nil
        isPaired = true
        if isRunning { startRelay() }
        append("Paired with Mac — signed iMessage rotate commands enabled")
        return ("200 OK", "{\"secret\":\"\(secret.base64EncodedString())\"}")
    }

    func rotateCommandVerified(_ verdict: RotateAuth.Verdict, via source: String = "iMessage") {
        let ts = Self.timeFormatter.string(from: Date())
        lastRotateCommand = "\(ts) \(source) \(verdict.description)"
        append("\(source) rotate command \(verdict.description)")
    }

    // MARK: - Relay

    private func startRelay() {
        relay.onState = { [weak self] s in self?.relayState = s }
        relay.onLog = { [weak self] line in self?.append(line) }
        relay.helloInfo = { [weak self] in
            var d: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"]
            if let ip = self?.publicIP, ip != "—" { d["publicIP"] = ip }
            return d
        }
        relay.onCommand = { [weak self] jobId, command in self?.relayCommand(jobId: jobId, command: command) }
        relay.start()
    }

    /// A signed command from the relay: verify it here (the relay can't), then
    /// run the same URL trigger as GET /__rotate.
    private func relayCommand(jobId: String, command: String) {
        let verdict = RotateAuth.verify(command)
        rotateCommandVerified(verdict, via: "Relay")
        var ack: [String: Any] = ["type": "ack", "jobId": jobId, "verdict": verdict.description]
        if publicIP != "—" { ack["publicIP"] = publicIP }
        relay.send(ack)
        guard verdict.isAccepted else { return }

        let (status, json) = requestRotate()
        if status.hasPrefix("202") {
            relayJob = (jobId, publicIP, false)
            relay.send(["type": "rotating", "jobId": jobId])
        } else {
            let why = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["error"] as? String
            relay.send(["type": "result", "jobId": jobId, "ok": false, "detail": why ?? status])
        }
    }

    /// Called once the shortcut has returned; reports when the public IP is known.
    private func finishRelayJob(ok: Bool, detail: String? = nil) {
        // Once the shortcut has reported success, a later callback can't undo it.
        guard let job = relayJob, !job.awaitingIP else { return }
        if ok {
            // Wait for the post-airplane public IP lookup (refreshPublicIP),
            // but don't hold the job forever if lookups keep failing.
            relayJob?.awaitingIP = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.relayJob?.id == job.id else { return }
                self.sendRelayResult(detail: "public IP lookup did not succeed within 60 s")
            }
            return
        }
        relayJob = nil
        relay.send(["type": "result", "jobId": job.id, "ok": ok, "detail": detail ?? ""])
    }

    private func sendRelayResult(detail: String? = nil) {
        guard let job = relayJob else { return }
        relayJob = nil
        var msg: [String: Any] = ["type": "result", "jobId": job.id, "ok": true]
        if job.oldIP != "—" { msg["oldIP"] = job.oldIP }
        if publicIP != "—" { msg["newIP"] = publicIP }
        if let detail { msg["detail"] = detail }
        relay.send(msg)
    }

    /// Callback from Shortcuts (x-success / x-cancel / x-error).
    func handleCallback(_ url: URL) {
        guard url.scheme == "mobilephoneproxy" else { return }
        let outcome = url.host ?? "?"
        let elapsed = rotateStartedAt.map { String(format: "%.0f s", Date().timeIntervalSince($0)) } ?? "?"
        rotateStartedAt = nil
        if outcome == "rotate-done" {
            append("Rotate shortcut finished after \(elapsed)")
            finishRelayJob(ok: true)
        } else {
            let msg = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "errorMessage" })?.value ?? ""
            append("Rotate shortcut \(outcome) after \(elapsed) \(msg)")
            finishRelayJob(ok: false, detail: "shortcut \(outcome) \(msg)")
        }
        refreshIPs()
        refreshPublicIP()
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
                    if self.relayJob?.awaitingIP == true {
                        self.sendRelayResult()
                    } else if ip != self.relayReportedIP {
                        self.relay.send(["type": "ip", "publicIP": ip])
                    }
                    self.relayReportedIP = ip
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
