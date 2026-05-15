import SwiftUI

@main
struct MobilePhoneProxyApp: App {
    @StateObject private var server = ProxyServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
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
