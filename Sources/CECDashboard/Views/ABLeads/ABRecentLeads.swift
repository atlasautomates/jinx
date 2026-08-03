import SwiftUI

// LEVEL 4: scrollable recent-leads list. Company in Adventor, figures in mono,
// status as a role-colored pill. Row hover = surface lift + a teal left marker
// slides in (bible §6 feedback).

struct ABStatusPill: View {
    let status: String
    private var role: ABStatusRole { ABStatusRole(status) }

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
        // A bare `.onTapGesture` carries no button trait and no accessibility
        // action: VoiceOver announced the row as a run of static text and could not
        // open the profile, which made every search hit mouse-only — in the one
        // feature whose entire purpose is finding a specific lead.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectable ? .isButton : [])
        .accessibilityLabel(selectable
            ? "\(lead.company), \(lead.industry), \(lead.location), \(lead.status)"
            : "\(lead.company), \(lead.status)")
        .accessibilityHint(selectable ? "Opens the lead profile" : "")
        .accessibilityAction { if selectable { onSelect?(lead) } }
        .onTapGesture { if selectable { onSelect?(lead) } }
    }
}

/// Column headers + the scrolling rows, without panel chrome. Shared by the leads
/// list and the search-results panel so a hit renders exactly like the lead it is.
///
/// This owns the tab's ONLY vertical scroll surface. It used to sit inside a
/// page-level `ScrollView`, and nesting two scroll views around a `LazyVStack`
/// is what made the list open part-scrolled with blank space above the first row:
/// the inner view is offered unbounded height, lays out against a content size it
/// then revises, and settles at a non-zero offset. The page no longer scrolls
/// (`ABLeadsView` sizes to the window), so this scroll view is bounded and starts
/// at the top — do not re-introduce an outer ScrollView above it.
struct ABLeadRowsTable: View {
    let leads: [ABLeadsData.Lead]
    var forcedHoverIndex: Int? = nil
    /// Offscreen render can't capture ScrollView content — swap to a clipped
    /// stack that cuts off mid-list (implying more, "scroll for more").
    var staticRender: Bool = false
    var onSelect: ((ABLeadsData.Lead) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            // `fixedSize` is load-bearing, not decoration. A VStack stretched taller
            // than its content hands the surplus to EVERY child that will take it,
            // and each then centres itself in the slot it was given — which is what
            // opened a band of empty space above the column headers and above the
            // first row, so the list looked scrolled-down-with-nothing-at-the-top
            // before anyone touched a scroll wheel. Pinning the header to its ideal
            // height leaves `rows` as the only greedy child.
            headerRow
                .padding(.horizontal, DesignTokens.space3)
                .fixedSize(horizontal: false, vertical: true)
            rows.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var rowsStack: some View {
        // Lazy in the app (the list runs to hundreds of rows); EAGER in a still.
        // `LazyVStack` outside a scroll view lays out against a container size
        // ImageRenderer never gives it, and renders a short list floating in the
        // middle of the panel — the preview then lies about where rows start,
        // which is exactly what previews exist to tell the truth about.
        if staticRender {
            VStack(spacing: 1) { rowViews }
        } else {
            LazyVStack(spacing: 1) { rowViews }
        }
    }

    @ViewBuilder
    private var rowViews: some View {
        ForEach(Array(leads.enumerated()), id: \.element.id) { idx, lead in
            ABLeadRow(lead: lead, forcedHover: forcedHoverIndex == idx, onSelect: onSelect)
        }
    }

    @ViewBuilder
    private var rows: some View {
        if staticRender {
            // Top of the list, clipped — the overflow reads as "scrollable". The
            // trailing Spacer is what pins it: a `.frame(maxHeight:.infinity,
            // alignment:.top)` around a LazyVStack still rendered a short list
            // vertically centred (visible in the leads-filtered still), which made
            // the preview lie about where rows begin.
            VStack(spacing: 0) {
                rowsStack.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        } else {
            ScrollView { rowsStack }
                .scrollBounceBehavior(.basedOnSize)
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

/// The tab's lead list: panel chrome + a title that states exactly what the rows
/// are (how many the filter matched, and whether the list is capped).
struct ABRecentLeadsTable: View {
    let leads: [ABLeadsData.Lead]
    /// Leads matching the current filter — may exceed `leads.count` (list cap).
    var matchingCount: Int? = nil
    /// One-line description of the active lens, shown beside the count.
    var filterSummary: String? = nil
    var forcedHoverIndex: Int? = nil
    var staticRender: Bool = false
    /// Row tap → open the lead profile (live tab); nil in the fixture/harness path.
    var onSelect: ((ABLeadsData.Lead) -> Void)? = nil

    private var total: Int { matchingCount ?? leads.count }
    private var capped: Bool { total > leads.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(spacing: DesignTokens.space2) {
                ABSectionLabel(filterSummary == nil ? "Leads" : "Filtered leads")
                Text("(\(total))")
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
                if let filterSummary {
                    Text(filterSummary)
                        .font(.adventor(DesignTokens.textXs))
                        .foregroundStyle(DesignTokens.accent)
                        .lineLimit(1)
                }
                Spacer()
                // Never let a capped list read as the whole set.
                Text(capped ? "showing newest \(leads.count)" : "scroll for more")
                    .font(.adventor(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
            }
            .padding(.horizontal, DesignTokens.space3)
            .fixedSize(horizontal: false, vertical: true)   // see ABLeadRowsTable

            if leads.isEmpty {
                // Don't blame a filter that isn't set: an empty book (or an empty
                // snapshot) would otherwise read as a filter artifact.
                ABMessageRow(icon: filterSummary == nil ? "tray" : "line.3.horizontal.decrease",
                             text: filterSummary == nil
                                 ? "No leads loaded yet."
                                 : "No lead matches this filter.",
                             tone: .muted, centered: true)
            } else {
                ABLeadRowsTable(leads: leads, forcedHoverIndex: forcedHoverIndex,
                                staticRender: staticRender, onSelect: onSelect)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, DesignTokens.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .abSurface(.surface, radius: DesignTokens.radiusLg)
    }
}
