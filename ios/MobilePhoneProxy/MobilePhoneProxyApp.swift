import SwiftUI

@main
struct MobilePhoneProxyApp: App {
    @StateObject private var server = ProxyServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
                .onOpenURL { url in server.handleCallback(url) }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    #if targetEnvironment(simulator)
                    // Auto-start in simulator so xcodebuild-driven smoke tests
                    // don't need UI automation.
                    server.start()
                    #endif
                }
        }
    }
}
