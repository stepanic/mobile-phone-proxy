import Foundation

enum InterfaceKind {
    case wifi
    case cellular
}

enum NetworkInterface {

    /// Returns the first IPv4 address found for the given interface kind.
    /// WiFi: `en0`, Cellular: `pdp_ip0..pdp_ip3`.
    static func address(for kind: InterfaceKind) -> String? {
        let targetNames: [String]
        switch kind {
        case .wifi:     targetNames = ["en0", "en1"]
        case .cellular: targetNames = ["pdp_ip0", "pdp_ip1", "pdp_ip2", "pdp_ip3"]
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var result: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isRunning = (flags & IFF_RUNNING) == IFF_RUNNING
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            if isUp, isRunning, !isLoopback, let addr = cur.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    let name = String(cString: cur.pointee.ifa_name)
                    if targetNames.contains(name) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let ok = getnameinfo(addr,
                                             socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                                             &host, socklen_t(host.count),
                                             nil, 0, NI_NUMERICHOST)
                        if ok == 0 {
                            result = String(cString: host)
                            break
                        }
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }

    /// Returns the Tailscale tailnet IPv4 address, if the Tailscale VPN is up.
    /// In the remote/parked model the Mac reaches the phone over the tailnet —
    /// the WiFi IP is irrelevant (and absent once WiFi is turned off). Tailscale
    /// assigns addresses from the 100.64.0.0/10 CGNAT range on a `utun*` interface.
    static func tailscaleAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            // CGNAT 100.64.0.0/10 → first octet 100, second 64...127.
            if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) {
                return ip
            }
        }
        return nil
    }
}
