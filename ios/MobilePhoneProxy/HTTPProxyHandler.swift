import Foundation
import Network

enum HTTPProxyHandler {

    static func handle(client: NWConnection, server: ProxyServer, queue: DispatchQueue) {
        client.start(queue: queue)
        readHeaders(client, server: server, queue: queue, accumulated: Data())
    }

    private static let headerLimit = 64 * 1024
    private static let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private static func readHeaders(_ client: NWConnection,
                                    server: ProxyServer,
                                    queue: DispatchQueue,
                                    accumulated: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isEOF, error in
            if let error = error {
                server.logLine("client recv error: \(error)")
                close(client, server: server)
                return
            }
            var buffer = accumulated
            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            if let range = buffer.range(of: crlfcrlf) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let leftover = buffer.subdata(in: range.upperBound..<buffer.count)
                guard let request = parseRequest(headerData) else {
                    sendErrorAndClose(client, status: "400 Bad Request", server: server)
                    return
                }
                dispatchRequest(request, leftover: leftover, client: client, server: server, queue: queue)
                return
            }

            if buffer.count > headerLimit {
                sendErrorAndClose(client, status: "431 Request Header Fields Too Large", server: server)
                return
            }

            if isEOF {
                close(client, server: server)
                return
            }

            readHeaders(client, server: server, queue: queue, accumulated: buffer)
        }
    }

    private struct ParsedRequest {
        var method: String
        var target: String
        var version: String
        var headerLines: [String]
        var host: String
        var port: UInt16
        var isConnect: Bool { method.uppercased() == "CONNECT" }
    }

    private static func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let method = parts[0]
        let target = parts[1]
        let version = parts[2]

        var host = ""
        var port: UInt16 = 80

        // RFC 9110 §7.6.1: the Connection header lists which other header names
        // are hop-by-hop and must be stripped before forwarding. Collect them
        // dynamically in addition to the well-known static set.
        var hopByHop: Set<String> = [
            "proxy-connection", "proxy-authorization", "connection", "keep-alive",
            "transfer-encoding", "te", "trailer", "upgrade",
        ]
        var rawHeaders: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            rawHeaders.append((name, value))
            if name.lowercased() == "connection" {
                for tok in value.split(separator: ",") {
                    hopByHop.insert(tok.trimmingCharacters(in: .whitespaces).lowercased())
                }
            }
        }

        var sanitizedHeaders: [String] = []
        for (name, value) in rawHeaders {
            let lower = name.lowercased()
            if hopByHop.contains(lower) { continue }
            if lower == "host" {
                let (h, p) = splitHostPort(value, defaultPort: port)
                host = h
                port = p
            }
            sanitizedHeaders.append("\(name): \(value)")
        }

        if method.uppercased() == "CONNECT" {
            let (h, p) = splitHostPort(target, defaultPort: 443)
            host = h
            port = p
        } else if let url = URL(string: target), let scheme = url.scheme {
            if scheme == "https" { port = UInt16(url.port ?? 443) }
            else if scheme == "http" { port = UInt16(url.port ?? 80) }
            if host.isEmpty, let h = url.host { host = h }
        }

        if host.isEmpty { return nil }

        return ParsedRequest(method: method, target: target, version: version,
                             headerLines: sanitizedHeaders, host: host, port: port)
    }

    private static func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16) {
        // Support IPv6 [::1]:443 form too.
        if s.hasPrefix("[") {
            if let end = s.firstIndex(of: "]") {
                let host = String(s[s.index(after: s.startIndex)..<end])
                let rest = s[s.index(after: end)...]
                if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) {
                    return (host, p)
                }
                return (host, defaultPort)
            }
        }
        if let colon = s.lastIndex(of: ":") {
            let host = String(s[..<colon])
            let portStr = s[s.index(after: colon)...]
            if let p = UInt16(portStr) { return (host, p) }
        }
        return (s, defaultPort)
    }

    private static func dispatchRequest(_ req: ParsedRequest,
                                        leftover: Data,
                                        client: NWConnection,
                                        server: ProxyServer,
                                        queue: DispatchQueue) {
        server.logLine("\(req.method) \(req.host):\(req.port)")

        guard let nwPort = NWEndpoint.Port(rawValue: req.port) else {
            sendErrorAndClose(client, status: "400 Bad Request", server: server)
            return
        }
        openUpstream(req: req, nwPort: nwPort, leftover: leftover,
                     client: client, server: server, queue: queue, forceCellular: true)
    }

    /// Builds outbound TCP parameters. On real hardware the first attempt pins the
    /// socket to the cellular interface; the simulator has no cellular interface so
    /// it always uses the default route (validates the protocol path end-to-end).
    private static func makeOutboundParams(forceCellular: Bool) -> NWParameters {
        let params = NWParameters.tcp
        #if !targetEnvironment(simulator)
        if forceCellular {
            params.requiredInterfaceType = .cellular
            params.prohibitedInterfaceTypes = [.wifi, .wiredEthernet, .loopback]
        }
        #endif
        if let tcpOpts = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOpts.connectionTimeout = 15
            tcpOpts.enableKeepalive = true
            tcpOpts.keepaliveIdle = 30
        }
        return params
    }

    private static func openUpstream(req: ParsedRequest,
                                     nwPort: NWEndpoint.Port,
                                     leftover: Data,
                                     client: NWConnection,
                                     server: ProxyServer,
                                     queue: DispatchQueue,
                                     forceCellular: Bool) {
        let upstream = NWConnection(host: NWEndpoint.Host(req.host), port: nwPort,
                                    using: makeOutboundParams(forceCellular: forceCellular))

        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if req.isConnect {
                    let resp = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: MobilePhoneProxy\r\n\r\n"
                    client.send(content: Data(resp.utf8), completion: .contentProcessed { err in
                        if let err = err {
                            server.logLine("client write err: \(err)")
                            close(client, upstream: upstream, server: server)
                            return
                        }
                        startRelay(client: client, upstream: upstream, server: server)
                    })
                } else {
                    let rebuilt = rebuildRequest(req)
                    var initial = Data(rebuilt.utf8)
                    initial.append(leftover)
                    upstream.send(content: initial, completion: .contentProcessed { err in
                        if let err = err {
                            server.logLine("upstream write err: \(err)")
                            close(client, upstream: upstream, server: server)
                            return
                        }
                        startRelay(client: client, upstream: upstream, server: server)
                    })
                }
            case .failed(let err):
                #if !targetEnvironment(simulator)
                if forceCellular {
                    // Android-parity fallback (mirrors the bindSocket→default-route
                    // recovery in the Kotlin port, commit a1cec3d). iOS can deny a
                    // cellular-pinned socket by system policy ("path unsatisfied").
                    // Retry once on the default route. This egresses via cellular
                    // ONLY IF WiFi is OFF (then the default route is pdp_ip0). With
                    // WiFi ON it would leak the WiFi/home IP — hence the loud log.
                    server.logLine("⚠️ CELLULAR PATH FAILED (\(err)) — retrying on DEFAULT route. Egress is cellular ONLY if WiFi is OFF.")
                    upstream.cancel()
                    openUpstream(req: req, nwPort: nwPort, leftover: leftover,
                                 client: client, server: server, queue: queue, forceCellular: false)
                    return
                }
                #endif
                server.logLine("upstream failed (\(req.host)): \(err)")
                sendErrorAndClose(client, status: "502 Bad Gateway", server: server, upstream: upstream)
            case .cancelled:
                break
            default:
                break
            }
        }

        upstream.start(queue: queue)
    }

    private static func rebuildRequest(_ req: ParsedRequest) -> String {
        // Convert absolute URI to origin-form path.
        var path = "/"
        if let url = URL(string: req.target) {
            if !url.path.isEmpty { path = url.path }
            if let q = url.query, !q.isEmpty { path += "?\(q)" }
        } else {
            path = req.target
        }
        var lines = ["\(req.method) \(path) \(req.version)"]
        var hasHost = false
        for h in req.headerLines {
            if h.lowercased().hasPrefix("host:") { hasHost = true }
            lines.append(h)
        }
        if !hasHost {
            lines.append("Host: \(req.host)\(req.port == 80 ? "" : ":\(req.port)")")
        }
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private static func startRelay(client: NWConnection, upstream: NWConnection, server: ProxyServer) {
        pump(from: client, to: upstream, server: server, isClientToUpstream: true)
        pump(from: upstream, to: client, server: server, isClientToUpstream: false)
    }

    private static func pump(from: NWConnection,
                             to: NWConnection,
                             server: ProxyServer,
                             isClientToUpstream: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isEOF, error in
            if let error = error {
                server.logLine("relay recv err: \(error)")
                close(from, upstream: to, server: server)
                return
            }
            if let data = data, !data.isEmpty {
                if isClientToUpstream { server.recordUp(data.count) }
                else { server.recordDown(data.count) }
                to.send(content: data, completion: .contentProcessed { err in
                    if let err = err {
                        server.logLine("relay send err: \(err)")
                        close(from, upstream: to, server: server)
                        return
                    }
                    if !isEOF {
                        pump(from: from, to: to, server: server, isClientToUpstream: isClientToUpstream)
                    } else {
                        // Half-close: signal end of write to peer.
                        to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                            close(from, upstream: to, server: server)
                        })
                    }
                })
            } else if isEOF {
                to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    close(from, upstream: to, server: server)
                })
            } else {
                pump(from: from, to: to, server: server, isClientToUpstream: isClientToUpstream)
            }
        }
    }

    private static let closedOnce = NSMutableSet()
    private static let closedLock = NSLock()

    private static func close(_ a: NWConnection, upstream b: NWConnection? = nil, server: ProxyServer) {
        a.cancel()
        b?.cancel()
        server.connectionClosed()
    }

    private static func close(_ a: NWConnection, server: ProxyServer) {
        a.cancel()
        server.connectionClosed()
    }

    private static func sendErrorAndClose(_ client: NWConnection,
                                          status: String,
                                          server: ProxyServer,
                                          upstream: NWConnection? = nil) {
        let body = "HTTP/1.1 \(status)\r\nProxy-Agent: MobilePhoneProxy\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        client.send(content: Data(body.utf8), isComplete: true, completion: .contentProcessed { _ in
            client.cancel()
            upstream?.cancel()
            server.connectionClosed()
        })
    }
}
