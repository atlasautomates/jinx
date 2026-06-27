import SwiftUI

/// Full-screen loading placeholder.
struct LoadingView: View {
    var body: some View {
        VStack(spacing: Space.s4) {
            ProgressView()
                .controlSize(.large)
                .tint(Palette.accent)
            Text("Loading leads…")
                .font(.ui(13))
                .foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgRoot)
    }
}

/// Full-screen error state with the operator-friendly reason + a retry affordance.
/// Distinct from an empty dashboard, so "broken" never reads as "no leads".
struct ErrorView: View {
    let message: String
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(StatusStyle.red.fg)

            Text("Couldn't load the dashboard")
                .font(.display(18, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Text(message)
                .font(.ui(12))
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)

            if let onRetry {
                Button(action: onRetry) {
                    Text("Retry").font(.ui(13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.accentBg))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Palette.accentBorder, lineWidth: 1))
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgRoot)
    }
}
