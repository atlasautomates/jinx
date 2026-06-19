import SwiftUI
import AppKit

@main
struct LeadDashboardApp: App {
    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    // Ensure the SPM executable launches as a normal foreground app.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 860)
    }
}
