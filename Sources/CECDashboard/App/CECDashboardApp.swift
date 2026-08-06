import SwiftUI
import AppKit

@main
struct CECDashboardApp: App {
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
        if CommandLine.arguments.contains("--check-write-key") {
            // Headless write-capability probe: reports configured/not (and
            // whether the ACL admits us without a prompt) — NEVER the value.
            // install-mac.sh uses it as the write-key acceptance step.
            let present = SupabaseWriteClient.isConfigured
            let readable = present && (SupabaseConfig.writeKey() != nil)
            print(readable ? "write-key: configured"
                  : present ? "write-key: PRESENT BUT UNREADABLE (ACL/prompt — re-grant with -T after delete)"
                  : "write-key: not configured (revisions read-only)")
            exit(readable || !present ? 0 : 1)
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
