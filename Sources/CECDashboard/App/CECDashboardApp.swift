import SwiftUI
import AppKit

@main
struct CECDashboardApp: App {
    init() {
        // Pre-boot intercept (bible §9): render a preview PNG and exit BEFORE any
        // store/network/Supabase subsystem constructs. Must come first.
        PreviewHarness.runIfRequested()
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
        if CommandLine.arguments.contains("--check-supabase") {
            SupabaseCheck.run()
        }
        if CommandLine.arguments.contains("--query") {
            LeadQuery.run()   // headless answer for automation / the Aris voice gate
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
        .windowStyle(.hiddenTitleBar)   // merge titlebar into content; traffic lights auto-hide (TitlebarHover)
        .defaultSize(width: 1280, height: 860)
    }
}
