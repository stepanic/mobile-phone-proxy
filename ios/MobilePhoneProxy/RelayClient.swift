import Foundation

/// Holds a WebSocket to the relay Worker (relay/ in the repo) so any cloud job
/// can ask for an IP rotation without reaching the tailnet:
///
///     caller → POST /v1/phones/<id>/rotate → Durable Object → this socket
///
/// The relay forwards the caller's signed MPP-ROTATE command untouched; the
/// HMAC is checked here by RotateAuth, so the relay itself cannot forge one.
/// The socket authenticates with a token derived from the same paired secret
/// (`macos/rotate-ip.sh --relay-token` prints it for the Worker's secret).
///
/// Airplane mode kills the socket on every rotation; reconnecting is the
/// normal path, and anything we need to tell the relay meanwhile is queued.
@MainActor
final class RelayClient: NSObject {
    /// Relay base URL and phone ID come from Info.plist (project.yml).
    static let baseURL = Bundle.main.object(forInfoDictionaryKey: "MPPRelayURL") as? String ?? ""
    static let phoneID = Bundle.main.object(forInfoDictionaryKey: "MPPRelayPhoneID") as? String ?? "iphone"

    var onState: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// Called with (jobId, command) when the relay delivers a rotate command.
    var onCommand: ((String, String) -> Void)?
    /// Fields for the hello message (current public IP, build).
    var helloInfo: (() -> [String: Any])?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var wanted = false
    private var backoff: TimeInterval = 2
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var lastPong = Date()
    private var outbox: [[String: Any]] = []

    func start() {
        guard !wanted else { return }
        guard let url = connectURL else { onState?("not configured"); return }
        guard RotateAuth.relayToken(phoneID: Self.phoneID) != nil else { onState?("not paired"); return }
        wanted = true
        connect(url)
    }

    func stop() {
        wanted = false
        reconnectWork?.cancel()
        teardown()
        onState?("off")
    }

    /// The network came back (e.g. new cellular address after airplane mode):
    /// retry now instead of waiting out the backoff.
    func reconnectNow() {
        guard wanted, !isOpen, let url = connectURL else { return }
        reconnectWork?.cancel()
        backoff = 2
        connect(url)
    }

    /// Sends now if connected, otherwise after the next hello.
    func send(_ msg: [String: Any]) {
        if isOpen { write(msg) } else {
            outbox.append(msg)
            if outbox.count > 20 { outbox.removeFirst(outbox.count - 20) }
        }
    }

    // MARK: - Connection

    private var connectURL: URL? {
        guard !Self.baseURL.isEmpty else { return nil }
        var s = Self.baseURL.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: "\(s)/v1/phones/\(Self.phoneID)/connect")
    }

    private func connect(_ url: URL) {
        teardown()
        guard let token = RotateAuth.relayToken(phoneID: Self.phoneID) else { onState?("not paired"); return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: req)
        self.session = session
        self.task = task
        onState?("connecting")
        task.resume()
        receive(on: task)
    }

    private func teardown() {
        pingTimer?.invalidate()
        pingTimer = nil
        isOpen = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func opened() {
        isOpen = true
        backoff = 2
        lastPong = Date()
        onState?("connected")
        var hello: [String: Any] = ["type": "hello"]
        hello.merge(helloInfo?() ?? [:]) { _, new in new }
        write(hello)
        let pending = outbox
        outbox.removeAll()
        pending.forEach(write)
        // Text "ping" is answered by the Durable Object's auto-response without
        // waking it; a missing pong means the socket is dead (NAT timeout etc.).
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.keepalive() }
        }
    }

    private func keepalive() {
        guard let task, isOpen else { return }
        if Date().timeIntervalSince(lastPong) > 70 {
            onLog?("Relay: no pong for 70 s — reconnecting")
            dropped(task)
            return
        }
        task.send(.string("ping")) { _ in }
    }

    private func dropped(_ from: URLSessionWebSocketTask, error: Error? = nil) {
        guard from === task else { return }   // stale callback from an old socket
        let wasOpen = isOpen
        teardown()
        guard wanted, let url = connectURL else { return }
        if wasOpen { onLog?("Relay disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")") }
        onState?("reconnecting in \(Int(backoff)) s")
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connect(url) }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        // Cap low: after airplane mode we want back within seconds, not minutes.
        backoff = min(backoff * 2, 15)
    }

    private func write(_ msg: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.onLog?("Relay send failed: \(error.localizedDescription)")
                self?.outbox.append(msg)   // retried after reconnect
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.dropped(task, error: error)
                case .success(let message):
                    if case .string(let s) = message { self.handle(s) }
                    if task === self.task { self.receive(on: task) }
                }
            }
        }
    }

    private func handle(_ text: String) {
        if text == "pong" { lastPong = Date(); return }
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              msg["type"] as? String == "rotate",
              let jobId = msg["jobId"] as? String,
              let command = msg["command"] as? String else { return }
        onCommand?(jobId, command)
    }
}

extension RelayClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            self.opened()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in self.dropped(webSocketTask) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        Task { @MainActor in
            if let http = ws.response as? HTTPURLResponse, http.statusCode == 401 {
                self.onLog?("Relay refused the token (401) — set PHONE_TOKENS from rotate-ip.sh --relay-token")
            }
            self.dropped(ws, error: error)
        }
    }
}
