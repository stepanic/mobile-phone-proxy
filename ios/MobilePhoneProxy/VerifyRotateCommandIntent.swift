import AppIntents

/// Shortcuts action used by the iMessage automation:
///
///     Message contains "MPP-ROTATE" → Run Immediately
///       Verify Rotate Command (Shortcut Input)
///       If <result> is true → Run Shortcut "Rotate IP"
///
/// Shortcuts cannot compute an HMAC itself, so the check runs here, in the
/// app's process, without bringing the app to the foreground.
struct VerifyRotateCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Verify Rotate Command"
    static var description = IntentDescription(
        "Returns true only for a fresh, correctly signed MPP-ROTATE message from the paired Mac.")
    static var openAppWhenRun = false

    @Parameter(title: "Message")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Verify rotate command in \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        IntentEventLog.record("invoked", message: message)
        let verdict = RotateAuth.verify(message)
        IntentEventLog.record(verdict.description)
        ProxyServer.current?.rotateCommandVerified(verdict)
        return .result(value: verdict.isAccepted)
    }
}

/// Registers the app's actions with Shortcuts so the app is listed there
/// (and its actions are indexed) without first being used from a shortcut.
struct MobilePhoneProxyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: VerifyRotateCommandIntent(),
                    phrases: ["Verify rotate command in \(.applicationName)"])
    }
}
