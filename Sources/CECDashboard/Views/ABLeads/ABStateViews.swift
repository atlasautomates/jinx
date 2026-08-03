import SwiftUI

// Loadable states for the live Leads tab, styled on ABTokens (DesignTokens) so the
// true-black world + teal identity hold through loading / error / stale. These
// mirror the shared StateViews patterns but never render a blank black screen on
// error and never depend on the fixture. (The other tabs keep the shared
// Palette-styled LoadingView/ErrorView.)

/// Full-tab loading placeholder — teal spinner on the near-black world.
struct ABLoadingView: View {
    var body: some View {
        ZStack {
            DesignTokens.bgRoot.ignoresSafeArea()
            VStack(spacing: DesignTokens.space4) {
                ProgressView()
                    .controlSize(.large)
                    .tint(DesignTokens.accent)
                Text("Loading leads…")
                    .font(.adventor(DesignTokens.textBase))
                    .foregroundStyle(DesignTokens.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgRoot)
        .preferredColorScheme(.dark)
    }
}

/// Full-tab error state with the operator-friendly reason + a retry affordance.
/// Distinct from an empty list, so "broken" never reads as "no leads".
struct ABErrorView: View {
    let message: String
    var onRetry: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        ZStack {
            DesignTokens.bgRoot.ignoresSafeArea()
            VStack(spacing: DesignTokens.space4) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(DesignTokens.statusRedText)

                Text("Couldn't load leads")
                    .font(.adventor(DesignTokens.textXl, bold: true))
                    .foregroundStyle(DesignTokens.textPrimary)

                Text(message)
                    .font(.adventor(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)

                if let onRetry {
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.adventor(DesignTokens.textBase, bold: true))
                            .foregroundStyle(DesignTokens.accent)
                            .padding(.horizontal, DesignTokens.space4)
                            .padding(.vertical, DesignTokens.space2)
                            .background(RoundedRectangle(cornerRadius: DesignTokens.radiusMd)
                                .fill(DesignTokens.accentBg))
                            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusMd)
                                .strokeBorder(hovering ? DesignTokens.borderHover : DesignTokens.accentBorder,
                                              lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(hovering ? 1.03 : 1.0)
                    .animation(ABMotion.fast, value: hovering)
                    .onHover { hovering = $0 }
                }
            }
            .padding(DesignTokens.space8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgRoot)
        .preferredColorScheme(.dark)
    }
}

/// Named degraded reads, shown beside the header stats. A bare `partial` flag was
/// carried through the whole pipeline and rendered NOWHERE: a failed `replies` read
/// looked exactly like a book with no replies (same pink 0.0%), and a failed
/// `send_queue` read drew a confident flat-zero outreach trend. This says which
/// figures are understated, in the user's words.
struct ABDegradedChip: View {
    let reads: [String]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DesignTokens.space1) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(reads.count == 1 ? "\(reads[0]) unavailable" : "\(reads.count) reads failed")
                .font(.adventor(DesignTokens.textXs, bold: true))
        }
        .foregroundStyle(DesignTokens.statusRedText)
        .padding(.horizontal, DesignTokens.space2)
        .padding(.vertical, 4)
        .background(Capsule().fill(DesignTokens.statusRedBg))
        .overlay(Capsule().strokeBorder(
            DesignTokens.statusRedText.opacity(hovering ? 0.7 : 0.35), lineWidth: 1))
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .help("These reads failed on the last load, so figures derived from them are "
            + "understated, not zero: \(reads.joined(separator: ", ")). Refresh to retry.")
        .accessibilityLabel("Degraded data: \(reads.joined(separator: ", ")) unavailable")
    }
}

/// Persistent marker for the dev-only offline fixture mode. Unconditional and
/// unmissable: a window of invented figures that looks exactly like the live one is
/// worse than having no offline mode.
struct ABFixtureBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "testtube.2")
                .font(.system(size: 11))
            Text(message)
                .font(.adventor(DesignTokens.textXs, bold: true))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DesignTokens.statusRedText)
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
        .background(RoundedRectangle(cornerRadius: DesignTokens.radiusMd)
            .fill(DesignTokens.statusRedBg))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusMd)
            .strokeBorder(DesignTokens.statusRedText.opacity(0.55), lineWidth: 1))
    }
}

/// Slim banner shown above the last-good data when a refresh failed (Loadable
/// `.stale`) — a warm, low-chroma note so degraded data is never mistaken for fresh.
struct ABStaleBanner: View {
    let message: String

    // Uses the amber `statusRed` family (hue 40) — NOT `statusOrange` (which
    // resolves to hue 350, the reply/reward pink). A degraded-data warning must not
    // borrow this view's reward hue.
    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.statusRedText)
            Text("Showing last loaded data — \(message)")
                .font(.adventor(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
        .background(RoundedRectangle(cornerRadius: DesignTokens.radiusMd)
            .fill(DesignTokens.statusRedBg))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusMd)
            .strokeBorder(DesignTokens.statusRedText.opacity(0.35), lineWidth: 1))
    }
}
