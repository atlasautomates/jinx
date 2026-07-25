import SwiftUI

/// Always-visible band of pinned leads at the top of the Leads tab (P5).
/// Chips reopen the profile in one click; renders nothing when no pins.
/// Re-skinned onto ABTokens (DesignTokens) to sit on the true-black ABLeads world:
/// flat, compact, teal identity, hover feedback (bible §5/§6).
struct PinnedStrip: View {
    @Environment(PinsModel.self) private var pinsModel
    @Environment(ProfilePresenter.self) private var presenter

    var body: some View {
        if !pinsModel.pins.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                ABSectionLabel("Pinned")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.space2) {
                        ForEach(pinsModel.pins) { ref in
                            PinnedChip(ref: ref, presenter: presenter)
                        }
                    }
                }
            }
            .padding(.horizontal, DesignTokens.space6)
            .padding(.top, DesignTokens.space4)
            .padding(.bottom, DesignTokens.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgRoot)
        }
    }
}

private struct PinnedChip: View {
    let ref: LeadRef
    let presenter: ProfilePresenter
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.accent)
            Text(ref.companyName?.nilIfEmpty ?? ref.email?.nilIfEmpty ?? "Lead")
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(hovering ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
        .background(Capsule().fill(hovering ? DesignTokens.bgHighlight : DesignTokens.bgElevated))
        .overlay(Capsule().strokeBorder(
            hovering ? DesignTokens.borderHover : DesignTokens.borderDefault, lineWidth: 1))
        .contentShape(Capsule())
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { presenter.active = ref }
    }
}
