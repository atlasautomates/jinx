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
