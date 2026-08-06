import SwiftUI

// LEVEL 4: scrollable recent-leads list. Company in Adventor, figures in mono,
// status as a role-colored pill. Row hover = surface lift + a teal left marker
// slides in (bible §6 feedback).

struct ABStatusPill: View {
    let status: String
    private let role: ABStatusRole

    /// Leads-tab statuses map through `ABStatusRole(_:)`.
    init(status: String) {
        self.status = status
        self.role = ABStatusRole(status)
    }

    /// Same pill, caller-supplied role — for vocabularies with their own
    /// status→role mapping (campaign + send-queue statuses).
    init(text: String, role: ABStatusRole) {
        self.status = text
        self.role = role
    }

    private var fg: Color {
        switch role {
        case .reward:  return DesignTokens.accentPinkStrong
        case .active:  return DesignTokens.accentStrong
        case .warn:    return DesignTokens.statusRedText
        case .neutral: return DesignTokens.textSecondary
        }
    }
    private var bg: Color {
        switch role {
        case .reward:  return DesignTokens.accentPinkBg
        case .active:  return DesignTokens.accentBg
        case .warn:    return DesignTokens.statusRedBg
        case .neutral: return DesignTokens.bgHighlight
        }
    }
    private var border: Color {
        switch role {
        case .reward:  return DesignTokens.accentPinkBorder
        case .active:  return DesignTokens.accentBorder
        case .warn:    return DesignTokens.statusRedText.opacity(0.4)
        case .neutral: return DesignTokens.borderDefault
        }
    }

    var body: some View {
        Text(status)
            .font(.adventor(DesignTokens.textXs, bold: true))
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, DesignTokens.space2)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
    }
}

private struct ABLeadRow: View {
    let lead: ABLeadsData.Lead
    var forcedHover: Bool = false
    /// Row tap → open the lead profile. nil (or a fixture row with no DB id) = inert.
    var onSelect: ((ABLeadsData.Lead) -> Void)? = nil
    @State private var hovering = false
    private var active: Bool { hovering || forcedHover }
    private var selectable: Bool { onSelect != nil && lead.leadID != nil }

    private var marker: Color {
        ABStatusRole(lead.status) == .reward ? DesignTokens.accentPink : DesignTokens.accent
    }

    var body: some View {
        HStack(spacing: DesignTokens.space3) {
            // left-edge marker slides in on hover
            RoundedRectangle(cornerRadius: 2)
                .fill(marker)
                .frame(width: 3, height: active ? 26 : 0)   // flat marker slides in (no bloom)

            Text(lead.company)
                .font(.adventor(DesignTokens.textBase, bold: active))
                .foregroundStyle(active ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                .frame(width: 210, alignment: .leading).lineLimit(1)

            Text(lead.industry)
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
                .frame(width: 150, alignment: .leading).lineLimit(1)

            Text(lead.location)
                .font(.abMono(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
                .frame(width: 130, alignment: .leading).lineLimit(1)

            Text(lead.source)
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
                .frame(width: 130, alignment: .leading).lineLimit(1)

            ABStatusPill(status: lead.status)
                .frame(width: 120, alignment: .leading)

            Spacer(minLength: 0)

            Text(lead.added)
                .font(.abMono(DesignTokens.textXs))
                .foregroundStyle(active ? DesignTokens.textSecondary : DesignTokens.textGhost)
        }
        .padding(.vertical, DesignTokens.space2)
        .padding(.horizontal, DesignTokens.space3)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusMd, style: .continuous)
                .fill(active ? DesignTokens.bgHighlight : Color.clear))
        .contentShape(Rectangle())
        .animation(ABMotion.fast, value: active)
        .onHover { hovering = $0 }
        .onTapGesture { if selectable { onSelect?(lead) } }
    }
}

struct ABRecentLeadsTable: View {
    let leads: [ABLeadsData.Lead]
    var forcedHoverIndex: Int? = nil
    /// Offscreen render can't capture ScrollView content — swap to a clipped
    /// stack that cuts off mid-list (implying more, "scroll for more").
    var staticRender: Bool = false
    /// Row tap → open the lead profile (live tab); nil in the fixture/harness path.
    var onSelect: ((ABLeadsData.Lead) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(spacing: DesignTokens.space2) {
                ABSectionLabel("Recent leads")
                Text("(\(leads.count))")
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
                Spacer()
                Text("scroll for more").font(.adventor(DesignTokens.textXs)).foregroundStyle(DesignTokens.textGhost)
            }
            .padding(.horizontal, DesignTokens.space3)

            headerRow.padding(.horizontal, DesignTokens.space3)

            rows
        }
        .padding(.vertical, DesignTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(.surface, radius: DesignTokens.radiusLg)
    }

    @ViewBuilder
    private var rowsStack: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(leads.enumerated()), id: \.element.id) { idx, lead in
                ABLeadRow(lead: lead, forcedHover: forcedHoverIndex == idx, onSelect: onSelect)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if staticRender {
            // Top of the list, clipped — the overflow reads as "scrollable".
            rowsStack
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { rowsStack }
        }
    }

    private var headerRow: some View {
        HStack(spacing: DesignTokens.space3) {
            Color.clear.frame(width: 3)
            header("Company", 210)
            header("Industry", 150)
            header("Location", 130)
            header("Source", 130)
            header("Status", 120)
            Spacer(minLength: 0)
            header("Added", nil)
        }
    }

    private func header(_ t: String, _ w: CGFloat?) -> some View {
        Text(t.uppercased())
            .font(.adventor(DesignTokens.textXs, bold: true))
            .tracking(1.0)
            .foregroundStyle(DesignTokens.textGhost)
            .frame(width: w, alignment: .leading)
    }
}
