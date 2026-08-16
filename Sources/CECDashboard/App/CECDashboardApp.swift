import SwiftUI
import AppKit

/// Dock-reopen fallback for the single `Window` scene: `WindowGroup` gave two
/// ways back to a closed window (⌘N + Dock); `Window` removes ⌘N, and if the
/// system's default reopen handling ever fails to restore the scene the app
/// would be a running process with no recoverable UI (contention lens). This
/// makes the reopen path explicit: surface the retained window if one exists.
final class CECAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
        return true   // let SwiftUI's own scene restoration run too
    }
}

@main
struct CECDashboardApp: App {
    @NSApplicationDelegateAdaptor(CECAppDelegate.self) private var appDelegate
    @FocusedValue(\.leadSearchFocus) private var leadSearchFocus

    init() {
        // Headless modes are mutually exclusive and each exits. Silently running the
        // first one listed meant `--selftest --query count` ran the selftest and
        // exited 0 WITHOUT answering the query — an automation that guessed wrong
        // consumed another mode's exit code and read it as success.
        let modes = ["--screenshot", "--selftest", "--check-supabase", "--query"]
            .filter(CommandLine.arguments.contains)
        if modes.count > 1 {
            FileHandle.standardError.write(Data(
                ("ERROR: \(modes.joined(separator: " ")) are mutually exclusive; pass one.\n").utf8))
            exit(1)
        }

        // Pre-boot intercept (bible §9): render a preview PNG and exit BEFORE any
        // store/network/Supabase subsystem constructs. Must come first.
        PreviewHarness.runIfRequested()
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
        if CommandLine.arguments.contains("--check-supabase") {
            SupabaseCheck.run()
        }
        // --check-write-key retired with the staged-copy revision editor (7.2:
        // the Campaigns tab and its write path are deprecated; the app is
        // read-only against the v_cec_* views).
        if CommandLine.arguments.contains("--query") {
            LeadQuery.run()   // headless answer for automation / the Aris voice gate
        }
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: the app is ONE surface since 7.2, and a
        // ⌘N-spawned sibling would duplicate the poll loops, register a second
        // pair of wake/activation observers, and fork the pins store into two
        // in-memory copies racing one JSON file (last writer wins — silent pin
        // loss). Single-instance is the enforced default, not a convention.
        Window("CEC Dashboard", id: "main") {
            RootView()
                .onAppear {
                    // Ensure the SPM executable launches as a normal foreground app.
                    NSApplication.shared.setActivationPolicy(.regular)
                    // No `ignoringOtherApps: true`: a headless App Intent
                    // (openAppWhenRun = false) launching the app in the
                    // background still creates this scene, and force-stealing
                    // focus would foreground the dashboard over whatever the
                    // user was doing mid-voice-query. A plain activate() is
                    // honored for user-initiated launches and ignored for
                    // background ones (contention lens).
                    NSApplication.shared.activate()
                }
        }
        .windowStyle(.hiddenTitleBar)   // merge titlebar into content; traffic lights auto-hide (TitlebarHover)
        .defaultSize(width: 1280, height: 860)
        .commands {
            // ⌘F as a real menu command, not a hidden Button carrying a
            // keyboardShortcut. The menu bar resolves key equivalents BEFORE the
            // view hierarchy, so a hidden button competes with the system's Find
            // item and loses; it also fires from whichever tab happens to be
            // selected, moving focus into a TextField the user cannot see. Owning
            // the item scopes it to the focused Leads tab (the focused value is
            // published only there) and makes it discoverable and announceable.
            CommandGroup(after: .textEditing) {
                Button("Find Lead…") { leadSearchFocus?.focus() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(leadSearchFocus == nil)
            }
        }
    }
}
