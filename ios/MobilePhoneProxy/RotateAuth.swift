import Foundation
import CryptoKit
import Security

/// Authenticates "rotate IP" commands that arrive as iMessages.
///
/// A Shortcuts automation ("Message contains MPP-ROTATE → Run Immediately")
/// fires for *any* sender, so the message itself must prove it came from the
/// paired Mac:
///
///     MPP-ROTATE v1 <unix-ts> <nonce> <hex HMAC-SHA256(secret, "MPP-ROTATE|v1|<ts>|<nonce>")>
///
/// The content is not secret — only unforgeable and single-use. HMAC proves
/// knowledge of the shared secret; the timestamp window and the seen-nonce set
/// stop a captured message from being replayed.
enum RotateAuth {

    static let prefix = "MPP-ROTATE"
    static let version = "v1"
    /// iMessage delivery + automation start was observed at 16–54 s; allow
    /// generous delivery delay and some clock skew between Mac and phone.
    static let maxAge: TimeInterval = 300
    static let maxFutureSkew: TimeInterval = 60

    enum Verdict: Equatable {
        case accepted
        case rejected(String)

        var isAccepted: Bool { self == .accepted }
        var description: String {
            switch self {
            case .accepted:           return "accepted"
            case .rejected(let why):  return "rejected: \(why)"
            }
        }
    }

    // MARK: - Verification

    static func verify(_ text: String, now: Date = Date()) -> Verdict {
        guard let secret = Keychain.load() else { return .rejected("not paired") }

        // The automation passes the whole message; find our command inside it.
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let start = tokens.firstIndex(of: prefix), tokens.count >= start + 5 else {
            return .rejected("malformed")
        }
        let ver = tokens[start + 1], tsStr = tokens[start + 2]
        let nonce = tokens[start + 3], sigHex = tokens[start + 4].lowercased()

        guard ver == version else { return .rejected("unsupported version \(ver)") }
        guard let ts = TimeInterval(tsStr) else { return .rejected("bad timestamp") }
        guard nonce.count >= 8, nonce.count <= 64,
              nonce.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return .rejected("bad nonce")
        }
        guard let sig = Data(hex: sigHex), sig.count == 32 else { return .rejected("bad signature encoding") }

        // CryptoKit's isValidAuthenticationCode compares in constant time.
        guard HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: Data(signedString(ts: tsStr, nonce: nonce).utf8),
                                                     using: SymmetricKey(data: secret)) else {
            return .rejected("bad signature")
        }

        let age = now.timeIntervalSince1970 - ts
        if age > maxAge { return .rejected("expired (\(Int(age)) s old)") }
        if age < -maxFutureSkew { return .rejected("timestamp in the future") }

        // Only consume the nonce once the signature is known good, so a forged
        // message cannot burn a nonce the Mac might still send.
        guard NonceStore.consume(nonce, now: now, window: maxAge + maxFutureSkew) else {
            return .rejected("replayed nonce")
        }
        return .accepted
    }

    static func signedString(ts: String, nonce: String) -> String {
        "\(prefix)|\(version)|\(ts)|\(nonce)"
    }

    // MARK: - Pairing

    static var isPaired: Bool { Keychain.load() != nil }

    /// WebSocket credential for the relay Worker, derived from the paired
    /// secret so nothing extra has to be provisioned on the phone. The Mac
    /// computes the same value (`rotate-ip.sh --relay-token`).
    static func relayToken(phoneID: String) -> String? {
        guard let secret = Keychain.load() else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("MPP-RELAY|v1|\(phoneID)".utf8),
                                                  using: SymmetricKey(data: secret))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the existing secret or creates one. Shared with the Mac once,
    /// over the tailnet, while the user has the pairing window open.
    static func secretForPairing() -> Data {
        if let s = Keychain.load() { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let s = Data(bytes)
        Keychain.save(s)
        return s
    }

    static func unpair() {
        Keychain.delete()
        NonceStore.reset()
    }

    // MARK: - Storage

    private enum Keychain {
        static let service = "com.stepanic.mobilephoneproxy.rotate"
        static let account = "hmac-secret"

        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        static func load() -> Data? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }

        static func save(_ data: Data) {
            delete()
            var q = query
            q[kSecValueData as String] = data
            // Readable while locked-after-first-unlock: the automation can fire
            // with the screen off.
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }

        static func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Seen nonces with their first-seen time, pruned past the validity window
    /// (an older nonce would fail the timestamp check anyway).
    private enum NonceStore {
        static let key = "rotateSeenNonces"
        static let lock = NSLock()

        static func consume(_ nonce: String, now: Date, window: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            var seen = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
            let cutoff = now.timeIntervalSince1970 - window
            seen = seen.filter { $0.value >= cutoff }
            guard seen[nonce] == nil else { return false }
            seen[nonce] = now.timeIntervalSince1970
            UserDefaults.standard.set(seen, forKey: key)
            return true
        }

        static func reset() {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        self = data
    }
}
