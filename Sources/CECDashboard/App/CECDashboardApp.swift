import SwiftUI
import AppKit

/// Dock-reopen for the single `Window` scene. Measured 2026-08-16: ⌘W
/// DESTROYS the scene's NSWindow (the app's window list goes empty), SwiftUI
/// answers terminate-after-last-window as true unless overridden below, and
/// the reopen delegate callback is NOT forwarded to this adaptor — so revival
/// is a didBecomeActive observer calling a bridged `openWindow(id: "main")`.
final class CECAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // UNPROVEN BELT: Info.plist carries no NSSupportsAutomaticTermination,
        // so this is very likely a no-op (review 2026-08-16) — the measured
        // load-bearing half is applicationShouldTerminateAfterLastWindowClosed
        // below. Kept as cheap insurance against a future SwiftUI opt-in.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "single-window dashboard: stay resident for Dock reopen")
        // Reopen via ACTIVATION, not the reopen delegate callback: SwiftUI's
        // internal application delegate does not reliably forward
        // applicationShouldHandleReopen to the adaptor (measured live — the
        // handler below never fired on a Dock-click-equivalent reopen). A
        // Dock click always ACTIVATES the app, and a plain NotificationCenter
        // observer involves no delegate forwarding at all. openWindow(id:) on
        // an already-visible Window scene just focuses it, so the at-launch
        // firing is harmless.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // MAIN-window visibility only: an auxiliary window (a lingering
                // sheet host, a future Settings scene) must not disable reopen,
                // and a MINIATURIZED main window reads !isVisible but restores
                // itself on Dock click — don't double-handle it (review).
                let mainAlive = NSApp.windows.contains {
                    ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain
                }
                guard !mainAlive else { return }
                NSLog("CECAppDelegate: %@", "activation with no main window — reopening")
                CECAppDelegate.reopenMainWindow?()
                // FAILURE SIGNAL: with terminate-after-close overridden, a
                // reopen that no-ops leaves a resident process whose only
                // escape is Force Quit — that state must at least name itself
                // (review MEDIUM: the old failure mode was a clean exit, this
                // one is a stuck process).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                        NSLog("CECAppDelegate: %@",
                              "reopen FAILED — app is resident with no window; the "
                              + "openWindow bridge did not revive the scene (SwiftUI "
                              + "behavior change?). Quit and relaunch; see SHIP-NOTES.")
                    }
                }
            }
        }
    }

    // disableAutomaticTermination alone was NOT enough — measured live
    // 2026-08-16: a real ⌘W still killed the process within 6s, because
    // SwiftUI answers this delegate query with true for a closed-scene app
    // unless the adaptor overrides it. This is the load-bearing half.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Bridge to SwiftUI's `openWindow(id: "main")`, captured by RootView on
    /// first appear. Needed because closing a `Window` scene DESTROYS its
    /// NSWindow (measured live: after ⌘W the app's window list is empty), so
    /// there is nothing to `makeKeyAndOrderFront` and SwiftUI does not
    /// recreate the scene from a bare reopen event — the only working revival
    /// is the scene system's own OpenWindowAction. `@MainActor`: written from
    /// RootView.onAppear, read on main-queue paths — enforced, not assumed.
    @MainActor static var reopenMainWindow: (() -> Void)?

    // MEASURED NOT TO FIRE as of 2026-08-16 (SwiftUI's internal delegate does
    // not forward this to the adaptor) — kept as the API-documented belt; the
    // didBecomeActive observer above is the live path.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        NSLog("CECAppDelegate: %@", "reopen callback fired (visible=\(hasVisibleWindows))")
        if !hasVisibleWindows {
            if let window = sender.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)   // hidden-but-alive window
            } else {
                Self.reopenMainWindow?()           // scene destroyed → recreate
            }
        }
        return true
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
