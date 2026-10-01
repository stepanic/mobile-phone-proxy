import Foundation
import UIKit

/// Persistent record of every "Verify Rotate Command" invocation.
///
/// The on-screen log lives in `ProxyServer` memory, but Shortcuts may run the
/// App Intent in a freshly launched process (or one where the SwiftUI scene
/// never came up), so those lines would be lost. This survives process
/// restarts and is served by GET /__log, which is how we tell "the intent never
/// ran" from "it ran and rejected the message".
enum IntentEventLog {
    private static let key = "intentEventLog"
    private static let limit = 50
    private static let lock = NSLock()

    @MainActor
    static func record(_ event: String, message: String? = nil) {
        var e: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "serverLive": ProxyServer.current != nil,
            "appState": appState,
        ]
        // The command is single-use and not secret, but keep only its head:
        // enough to see what the automation actually passed in.
        if let message { e["message"] = String(message.prefix(48)) }

        lock.lock(); defer { lock.unlock() }
        var all = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        all.append(e)
        if all.count > limit { all.removeFirst(all.count - limit) }
        UserDefaults.standard.set(all, forKey: key)
    }

    static var events: [[String: Any]] {
        UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
    }

    @MainActor
    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
