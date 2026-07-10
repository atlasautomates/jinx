import SwiftUI

/// Always-visible band of pinned leads at the top of the Leads tab (P5).
/// Chips reopen the profile in one click; renders nothing when no pins.
struct PinnedStrip: View {
    @Environment(PinsModel.self) private var pinsModel
    @Environment(ProfilePresenter.self) private var presenter

    var body: some View {
        if !pinsModel.pins.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                SectionLabel("Pinned")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        ForEach(pinsModel.pins) { ref in
                            chip(ref)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.s5)
            .padding(.top, Space.s3)
            .background(Palette.bgRoot)
        }
    }

    private func chip(_ ref: LeadRef) -> some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.accent)
            Text(ref.companyName?.nilIfEmpty ?? ref.email?.nilIfEmpty ?? "Lead")
                .font(.ui(12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(Capsule().fill(Palette.bgElevated))
        .overlay(Capsule().stroke(Palette.borderDefault, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { presenter.active = ref }
    }
}
