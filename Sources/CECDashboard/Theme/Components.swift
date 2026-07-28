import AppKit
import SwiftUI

/// Card surface — the standard panel chrome for every widget.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(Palette.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .stroke(Palette.borderDefault, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4)
    }
}

/// Small uppercase muted label used as a widget header.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.ui(11, weight: .medium))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textMuted)
    }
}

/// Pill badge for statuses (sentiment, stage, campaign state).
struct Badge: View {
    let text: String
    let style: StatusStyle

    var body: some View {
        Text(text)
            .font(.ui(11, weight: .medium))
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(style.bg))
            .foregroundStyle(style.fg)
            .lineLimit(1)
    }
}

// MARK: - Click-to-copy

/// General-pasteboard write for a copied field value.
///
/// Returns whether the write actually landed. This is NOT ceremony: `setString`
/// is fallible, and because `clearContents()` has already run by then, a failed
/// write leaves the pasteboard EMPTY — the user's previous clipboard destroyed
/// and nothing put in its place. A dropped result plus an unconditional
/// checkmark means they paste nothing and don't know why. Gate the
/// confirmation on this.
@MainActor
enum Pasteboard {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        if !ok { NSLog("Pasteboard: copy failed (%d chars)", text.count) }
        return ok
    }
}

/// Forced interaction state for still renders — same idea as ABRecentLeads'
/// `forcedHoverIndex`: a `--screenshot` pass can't hover or click, so the state
/// is injected (bible §9 — design work is iterated against rendered output).
enum CopyDemoState { case none, hover, copied }

/// Names which field a still render shows in which state. Only ever honored on
/// the preview path — the caller gates it, so a live view cannot paint a
/// "Copied" checkmark over a field nobody clicked.
struct CopyDemo: Equatable {
    var hoverLabel: String?
    var copiedLabel: String?

    init(hoverLabel: String? = nil, copiedLabel: String? = nil) {
        self.hoverLabel = hoverLabel
        self.copiedLabel = copiedLabel
    }

    /// Empty strings match nothing — an unset label must never collide with a
    /// fact whose label is somehow blank.
    func state(for label: String) -> CopyDemoState {
        if let copiedLabel, !copiedLabel.isEmpty, label == copiedLabel { return .copied }
        if let hoverLabel, !hoverLabel.isEmpty, label == hoverLabel { return .hover }
        return .none
    }
}

/// How the copy target presents itself.
/// - `value`: the whole rendered value is the button (inline fact grids).
/// - `glyph`: only a small icon button, for surfaces whose text stays
///   selectable (the opener/offer prose blocks).
enum CopyableStyle { case value, glyph }

/// AppKit owns the pointing-hand cursor via a cursor rect.
///
/// The obvious `NSCursor.pointingHand.push()` / `.pop()` on hover is a trap: the
/// stack is PER-PROCESS, `pop()` at depth 1 is a no-op, and SwiftUI does not
/// guarantee `onHover(false)` or `onDisappear` on the paths that matter —
/// scrolling a hovered row out from under a stationary pointer, ⌘-Tab, Mission
/// Control, or ⌘W with the sheet open. Every missed exit strands a pushed cursor
/// for the life of the process, and this app stays open for days. Cursor rects
/// are re-established by AppKit on scroll, resize, and window activation, and
/// die with the view — nothing can leak.
private struct PointingHandCursor: NSViewRepresentable {
    final class CursorView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        /// Stay click-through so the SwiftUI Button underneath still gets the hit.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// True while rendering through the `--screenshot` harness.
///
/// `ImageRenderer` cannot rasterize an `NSViewRepresentable` — it paints a
/// yellow "unsupported" placeholder over the whole row instead. Any AppKit-backed
/// view therefore has to opt out of still renders, and the harness is the only
/// thing that knows it is one.
private struct StaticRenderKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var isStaticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

/// How long the confirmation holds before the glyph reverts.
private let copyConfirmHold: Duration = .milliseconds(1200)

/// A field value that copies itself on click.
///
/// Hover reveals a copy glyph and lifts the surface one lightness step plus a
/// 1px edge (bible §5 — on a near-black world the step alone is too quiet to
/// read); a click writes to the pasteboard and flips to a checkmark in the
/// accent hue for ~1.2s (bible §6 — every interactive element acknowledges).
/// The glyph holds its slot at zero opacity when idle, so revealing it never
/// reflows the row.
///
/// This view OWNS its Text rather than taking a `@ViewBuilder`. That is the
/// whole point: with a caller-supplied label, nothing stops one string being
/// rendered and a different one copied, and `--selftest` cannot see the
/// difference (QA proved it — a truncating `Text` shipped green). One stored
/// `value` feeds both the render and the clipboard, so they cannot diverge.
struct CopyableValue: View {
    let value: String
    /// Field name, for the tooltip and VoiceOver ("Copy industry").
    var label: String?
    var style: CopyableStyle = .value
    var demo: CopyDemoState = .none

    /// What was last copied — keyed to the VALUE, not to a Bool. SwiftUI reuses
    /// a row's @State when the identity is stable (the fact grid keys on the
    /// label, a fixed vocabulary shared by every lead), so a Bool could leave a
    /// checkmark asserting "copied" over a DIFFERENT lead's value. Comparing the
    /// string makes that unrepresentable.
    @State private var outcome: Outcome?
    @State private var hovering = false
    /// Bumped per click; drives the confirmation timer through `.task(id:)`.
    @State private var clicks = 0
    @Environment(\.isStaticRender) private var isStaticRender

    private enum Outcome: Equatable { case copied(String), failed(String) }

    private var isHovering: Bool { hovering || demo == .hover }
    private var isCopied: Bool { demo == .copied || outcome == .copied(value) }
    private var isFailed: Bool { outcome == .failed(value) }

    var body: some View {
        Button(action: performCopy) { surface }
        .buttonStyle(.plain)
        .focusable()                       // Tab reaches it under Full Keyboard Access
        .help(helpText)
        .accessibilityLabel(hint)
        .accessibilityValue(value)
        .contextMenu {                     // right-click Copy, and a non-drag path
            Button("Copy", action: performCopy)
        }
        .onHover { hovering = $0 }         // visual state only — AppKit owns the cursor
        .task(id: clicks) {
            // Capture the id this run belongs to. @State reads are LIVE, so
            // testing `clicks` after the sleep without this would let a finished
            // timer clear a NEWER confirmation (leaving the second copy silent).
            let generation = clicks
            guard generation > 0, outcome != nil else { return }
            do { try await Task.sleep(for: copyConfirmHold) } catch {
                // Cancelled: a newer click owns the state — unless nothing
                // superseded us (a dismissal), in which case clear it so the
                // confirmation cannot strand.
                if clicks == generation { outcome = nil }
                return
            }
            guard clicks == generation else { return }
            outcome = nil
        }
    }

    /// One action behind every copy path (click, ⏎/Space, context menu). The
    /// `clicks` bump is what starts the confirmation timer — a path that sets
    /// `outcome` without it leaves the checkmark on forever.
    private func performCopy() {
        outcome = Pasteboard.copy(value) ? .copied(value) : .failed(value)
        clicks += 1
        // The glyph is mouse-only feedback; announce for VoiceOver too — on
        // FAILURE as well, or a VoiceOver user gets silence and assumes success
        // (the warning glyph is accessibilityHidden).
        if case .copied = outcome {
            AccessibilityNotification.Announcement(announcement).post()
        } else {
            AccessibilityNotification.Announcement("Copy failed").post()
        }
    }

    private var hint: String {
        label.map { "Copy \($0.lowercased())" } ?? "Copy value"
    }

    private var announcement: String {
        label.map { "Copied \($0.lowercased())" } ?? "Copied"
    }

    /// The tooltip carries the full value: with selection gone this is the only
    /// way to inspect a value the Grid tail-truncated. Pinned to one string —
    /// AppKit does not refresh an already-visible tooltip, so a mid-hover flip
    /// to "Copied" would never render anyway.
    private var helpText: String {
        style == .glyph ? hint : "\(hint)\n\(value)"
    }

    @ViewBuilder
    private var surface: some View {
        Group {
            switch style {
            case .value:
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    // `verbatim:` so a value that looks like markup ("**x**")
                    // can never render styled while copying the raw asterisks.
                    Text(verbatim: value)
                        .font(.ui(12))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    glyph
                }
            case .glyph:
                glyph              // always visible: it IS the button
            }
        }
        .padding(.horizontal, hInset)
        .padding(.vertical, vInset)
        .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .stroke(stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .overlay {
            // Installed unconditionally: gating on `isHovering` would put a
            // SwiftUI callback back in the loop of the very mechanism whose
            // point is not to depend on one (a missed onHover(true) — the row
            // scrolling into place under a stationary pointer — would mean no
            // pointing hand at all). Only ImageRenderer is excluded: it cannot
            // rasterize an NSViewRepresentable and paints a yellow placeholder
            // over the whole row instead.
            if !isStaticRender { PointingHandCursor().allowsHitTesting(false) }
        }
        .animation(ABMotion.fast, value: isHovering)
        .animation(ABMotion.fast, value: isCopied)
    }

    private var glyph: some View {
        Image(systemName: isFailed ? "exclamationmark.triangle"
                        : isCopied ? "checkmark" : "square.on.square")
            .font(.ui(9, weight: .semibold))
            .foregroundStyle(isFailed ? StatusStyle.orange.fg
                           : isCopied ? Palette.accent : Palette.textMuted)
            .opacity(isCopied || isFailed || isHovering || style == .glyph ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        if isFailed { return StatusStyle.orange.bg }
        if isCopied { return Palette.accentBg }
        return isHovering ? Palette.bgHighlight : .clear
    }

    /// Hover pairs the lightness step with a 1px edge (bible §5): on a near-black
    /// world one surface step alone is too quiet to read as a response.
    private var stroke: Color {
        if isFailed { return StatusStyle.orange.fg.opacity(0.5) }
        if isCopied { return Palette.accentBorder }
        return isHovering ? Palette.borderHover : .clear
    }

    private var hInset: CGFloat { Space.s1 }
    private var vInset: CGFloat { Space.s1 / 2 }
}

/// Minimal dependency-free sparkline for KPI cards.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = values.max() ?? 1
            let minV = values.min() ?? 0
            let range = max(maxV - minV, 0.0001)
            Path { path in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat((v - minV) / range))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
