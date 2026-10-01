import Foundation
import Network

/// Looks up the phone's *public* egress IP — the address websites (and the Mac
/// going through this proxy) actually see.
///
/// The "Cellular IP" shown from `pdp_ip0` is only the carrier-internal address
/// (e.g. 10.x.x.x); Telemach mobile sits behind CGNAT, which translates it to a
/// shared public 86.33.x.x address. That public address is only observable from
/// outside, so we ask a "what is my IP" service over a socket pinned to the
/// cellular interface — the same path `HTTPProxyHandler` uses for upstream.
enum PublicIP {

    private static let host = "api.ipify.org"
    private static let timeout: TimeInterval = 10

    static func fetch(queue: DispatchQueue, completion: @escaping (Result<String, Error>) -> Void) {
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        params.requiredInterfaceType = .cellular

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params)
        var finished = false
        let finish: (Result<String, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(result)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET / HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: MobilePhoneProxy\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error { finish(.failure(error)) }
                })
                receiveAll(conn, accumulated: Data()) { data in
                    if let ip = parseBody(data) {
                        finish(.success(ip))
                    } else {
                        finish(.failure(LookupError.badResponse))
                    }
                }
            case .failed(let error), .waiting(let error):
                finish(.failure(error))
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(LookupError.timeout)) }
    }

    private static func receiveAll(_ conn: NWConnection, accumulated: Data, done: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                done(buffer)
            } else {
                receiveAll(conn, accumulated: buffer, done: done)
            }
        }
    }

    /// ipify returns the bare IP as the body. Validate it parses as an address
    /// so an HTML error page never ends up displayed as "the IP".
    private static func parseBody(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let split = text.range(of: "\r\n\r\n") else { return nil }
        let status = text[..<split.lowerBound].split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[1] == "200" else { return nil }
        let body = text[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(body) != nil || IPv6Address(body) != nil else { return nil }
        return body
    }

    enum LookupError: LocalizedError {
        case timeout, badResponse
        var errorDescription: String? {
            switch self {
            case .timeout:     return "timed out"
            case .badResponse: return "unexpected response"
            }
        }
    }
}
