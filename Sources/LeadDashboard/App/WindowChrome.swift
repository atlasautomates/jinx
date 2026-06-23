import SwiftUI
import AppKit

/// Captures the hosting `NSWindow` so we can tweak native chrome from SwiftUI.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        resolve(view, attemptsLeft: 10)   // retry: the view may not be in a window on the first tick
        return view
    }

    private func resolve(_ view: NSView, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
            guard let view else { return }
            if let window = view.window {
                onResolve(window)
            } else if attemptsLeft > 0 {
                resolve(view, attemptsLeft: attemptsLeft - 1)
            }
            // else: gave up after ~0.5s → native chrome stays (fail-open)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hides the window's traffic-light buttons by default and reveals them only while
/// the pointer is over the title strip.
///
/// A transparent, click-through hover view is layered over the titlebar (the buttons'
/// superview). Because its tracking area spans the whole titlebar — including the
/// buttons, which are children — moving the pointer onto a button stays *inside* the
/// tracked rect, so there's no enter/exit flicker. `hitTest` returns nil so clicks
/// still reach the revealed buttons.
@MainActor
final class TitlebarHover {
    private final class HoverView: NSView {
        var onEnter: () -> Void = {}
        var onExit: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // pass clicks through

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onEnter() }
        override func mouseExited(with event: NSEvent) { onExit() }
    }

    private var installed = false

    func attach(to window: NSWindow) {
        guard !installed else { return }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview
        else {
            // Private titlebar hierarchy not as expected (e.g. a future macOS) →
            // leave native chrome intact, and log so the regression is diagnosable.
            NSLog("TitlebarHover: window button hierarchy not found; using native chrome")
            return
        }
        installed = true

        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        let setHidden: (Bool) -> Void = { hidden in buttons.forEach { $0.isHidden = hidden } }
        setHidden(true)   // hidden by default

        let hover = HoverView(frame: titlebar.bounds)
        hover.autoresizingMask = [.width, .height]
        hover.onEnter = { setHidden(false) }
        hover.onExit = { setHidden(true) }
        titlebar.addSubview(hover)
    }
}
