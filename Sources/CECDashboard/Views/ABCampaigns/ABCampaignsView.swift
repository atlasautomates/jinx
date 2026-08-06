import SwiftUI

// Campaigns tab drill-down (design brief: .claude/design/briefs/campaigns-drilldown.md).
// Level 1: every campaign, status on the row. Click → level 2: the campaign's
// leads. Click → level 3: correspondence with that lead (ABCorrespondence.swift).
// Shares the AB world (teal identity, pink inbound/reply role); reads are
// anon/GET-only, the sole write is the staged-copy revision editor at level 3.

// MARK: - Status → role mappings (campaign vocabularies)

/// Role mapping for the campaign/queue vocabularies — same four roles the
/// Leads tab uses, so color meaning stays consistent app-wide.
enum ABCampaignRoles {
    /// `campaigns.status`: active/paused/completed.
    static func campaign(_ status: String) -> ABStatusRole {
        switch status.lowercased() {
        case "active":              return .active
        case "paused":              return .warn
        default:                    return .neutral   // completed, unknown
        }
    }

    /// `campaign_leads.status`: the per-lead funnel state.
    static func rosterLead(_ status: String) -> ABStatusRole {
        switch status.lowercased() {
        case "replied", "booked":                             return .reward
        case "sent":                                          return .active
        case "bounced", "unsubscribed", "do_not_contact",
             "failed":                                        return .warn
        default:                                              return .neutral
        }
    }

    /// `send_queue.status`: pending/sending/sent/failed/skipped.
    static func queue(_ status: String) -> ABStatusRole {
        switch status.lowercased() {
        case "sent", "sending":     return .active
        case "failed":              return .warn
        default:                    return .neutral   // pending, skipped, unknown
        }
    }
}

// MARK: - Root view

struct ABCampaignsView: View {
    var inputs: CampaignInputs
    let drill: CampaignDrillModel
    /// Offscreen ImageRenderer can't capture ScrollView content — the harness
    /// sets this true to swap ScrollViews for clipped stacks (house pattern).
    var staticRender: Bool = false
    var onRefresh: (() -> Void)? = nil
    var isRefreshing: Bool = false
    var staleMessage: String? = nil

    var body: some View {
        ZStack(alignment: .top) {
            DesignTokens.bgRoot.ignoresSafeArea()

            // Same single overhead light source as the Leads tab (bible §5).
            LinearGradient(colors: [DesignTokens.accent.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                if let staleMessage { ABStaleBanner(message: staleMessage) }
                header
                if inputs.partial {
                    ABDegradedCaption(text: "Some campaign reads were degraded or truncated — counts may under-report.")
                }
                if drilledCampaignVanished {
                    ABDegradedCaption(text: "This campaign is no longer in the live list — showing the last known snapshot.")
                }
                levelContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, DesignTokens.space6)
            .padding(.vertical, DesignTokens.space5)
        }
        .background(DesignTokens.bgRoot)
        .preferredColorScheme(.dark)
        .background {
            // Esc pops one drill level (design brief §8). A hidden button with
            // a keyboard shortcut is the reliable form — onExitCommand needs
            // focus the drill tables don't take. NEVER while the revision
            // editor is open or saving: the key-equivalent path outruns the
            // focused field, and popping destroys the draft (delta review).
            Button("") {
                guard !drill.isEditorOpen, !drill.isSavingRevision else { return }
                if drill.lead != nil { drill.popToLeads() }
                else if drill.campaign != nil { drill.popToCampaigns() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// True when the drilled campaign no longer exists in the refreshed list —
    /// the drill keeps rendering its snapshot, but honestly labeled.
    private var drilledCampaignVanished: Bool {
        guard let campaign = drill.campaign else { return false }
        return !inputs.summaries.contains { $0.id == campaign.id }
    }

    // MARK: Level switching (in-place drill, ABMotion transition — brief §7a)

    @ViewBuilder
    private var levelContent: some View {
        // One structural arm per LEVEL, keyed by ids — SwiftUI keeps subtree
        // identity across data refreshes within a level (S05 lesson), while
        // level changes animate as a swap.
        Group {
            if let campaign = drill.campaign, let lead = drill.lead {
                ABCorrespondenceView(
                    campaign: liveSummary(campaign), lead: lead, drill: drill,
                    staticRender: staticRender)
                    .id("thread-\(campaign.id)-\(lead.leadId)")
                    .transition(levelTransition)
            } else if let campaign = drill.campaign {
                ABCampaignLeadsView(
                    summary: liveSummary(campaign), drill: drill,
                    staticRender: staticRender)
                    .id("leads-\(campaign.id)")
                    .transition(levelTransition)
            } else {
                ABCampaignTable(
                    summaries: inputs.summaries, staticRender: staticRender,
                    onSelect: { summary in Task { await drill.openCampaign(summary) } })
                    .transition(levelTransition)
            }
        }
        .animation(ABMotion.normal, value: levelKey)
    }

    private var levelTransition: AnyTransition {
        .opacity.combined(with: .offset(y: 8))
    }

    private var levelKey: String {
        if let c = drill.campaign, let l = drill.lead { return "3-\(c.id)-\(l.leadId)" }
        if let c = drill.campaign { return "2-\(c.id)" }
        return "1"
    }

    /// Render from the LIVE summary when the periodic refresh replaced it —
    /// the drill header must not disagree with the list it came from.
    private func liveSummary(_ selected: CampaignSummary) -> CampaignSummary {
        inputs.summaries.first { $0.id == selected.id } ?? selected
    }

    // MARK: Header (breadcrumb + aggregate stats + refresh)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignTokens.space1) {
                breadcrumb
                Rectangle().fill(DesignTokens.accent)
                    .frame(width: 34, height: 2)   // flat accent rule (no glow on this tab)
            }
            Spacer()
            HStack(spacing: DesignTokens.space4) {
                summaryStat(value: inputs.summaries.count, label: "campaigns",
                            color: DesignTokens.textSecondary)
                summaryStat(value: activeCount, label: "active",
                            color: DesignTokens.accent)
                summaryStat(value: totalReplies, label: "replies",
                            color: DesignTokens.accentPink)
                if let onRefresh {
                    ABCampaignsRefreshButton(isRefreshing: isRefreshing, action: onRefresh)
                }
            }
        }
    }

    private var activeCount: Int {
        inputs.summaries.filter { $0.status.lowercased() == "active" }.count
    }
    private var totalReplies: Int {
        inputs.summaries.reduce(0) { $0 + $1.totalReplies }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: DesignTokens.space2) {
            if drill.campaign == nil {
                Text("Campaigns")
                    .font(.adventor(DesignTokens.textXl, bold: true))
                    .foregroundStyle(DesignTokens.textPrimary)
            } else {
                ABCrumbLink(text: "Campaigns") { drill.popToCampaigns() }
                crumbSeparator
                // Breadcrumb names route through liveSummary too — one source
                // of truth per render, so a renamed campaign can't show two
                // names on one screen (state-machine review F4).
                if let campaign = drill.campaign, drill.lead == nil {
                    Text(liveSummary(campaign).name)
                        .font(.adventor(DesignTokens.textXl, bold: true))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1)
                } else if let campaign = drill.campaign, let lead = drill.lead {
                    ABCrumbLink(text: liveSummary(campaign).name) { drill.popToLeads() }
                    crumbSeparator
                    Text(lead.companyName?.nilIfEmpty ?? lead.email?.nilIfEmpty ?? "Lead")
                        .font(.adventor(DesignTokens.textXl, bold: true))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var crumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: DesignTokens.textSm, weight: .semibold))
            .foregroundStyle(DesignTokens.textGhost)
    }

    private func summaryStat(value: Int, label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space1) {
            Text(value, format: .number)
                .font(.abMono(DesignTokens.textBase, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
        }
    }
}

// MARK: - Breadcrumb link (ancestor levels — interactive, §6 feedback)

struct ABCrumbLink: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.adventor(DesignTokens.textXl, bold: false))
                .foregroundStyle(hovering ? DesignTokens.accentStrong : DesignTokens.textMuted)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .pointingCursor
    }
}

// MARK: - Shared bits

/// One-line degradation caption (data honesty — house rule). Amber family, so
/// degraded never borrows the reward pink.
struct ABDegradedCaption: View {
    let text: String
    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DesignTokens.textXs - 1))
                .foregroundStyle(DesignTokens.statusRedText)
            Text(text)
                .font(.adventor(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textMuted)
            Spacer(minLength: 0)
        }
    }
}

private struct ABCampaignsRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: DesignTokens.textSm, weight: .semibold))
                .foregroundStyle(hovering ? DesignTokens.accentStrong : DesignTokens.accent)
                .padding(DesignTokens.space2)
                .background(Circle().fill(hovering ? DesignTokens.accentBg : Color.clear))
                .overlay(Circle().strokeBorder(
                    hovering ? DesignTokens.accentBorder : DesignTokens.borderDefault, lineWidth: 1))
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? ABMotion.spin : ABMotion.fast, value: isRefreshing)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .scaleEffect(hovering && !isRefreshing ? 1.06 : 1.0)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .help("Refresh campaigns")
    }
}

/// Hand cursor on hover. STATEFUL: rows here navigate on click, which removes
/// the hovered view mid-hover — SwiftUI does not guarantee `onHover(false)`
/// then, so a bare push/pop pair leaks a cursor per drill click (platform
/// review). `onDisappear` balances the stack.
private struct PointingCursor: ViewModifier {
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    /// Hand cursor on hover — links/rows that navigate.
    var pointingCursor: some View { modifier(PointingCursor()) }
}

// MARK: - Level 1: the campaign table

struct ABCampaignTable: View {
    let summaries: [CampaignSummary]
    var staticRender: Bool = false
    var forcedHoverIndex: Int? = nil
    var onSelect: ((CampaignSummary) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(spacing: DesignTokens.space2) {
                ABSectionLabel("All campaigns")
                Text("(\(summaries.count))")
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
                Spacer()
                Text("click a campaign for its leads")
                    .font(.adventor(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
            }
            .padding(.horizontal, DesignTokens.space3)

            headerRow.padding(.horizontal, DesignTokens.space3)

            if summaries.isEmpty {
                Text("No campaigns yet.")
                    .font(.adventor(DesignTokens.textBase))
                    .foregroundStyle(DesignTokens.textMuted)
                    .padding(DesignTokens.space4)
            } else {
                rows
            }
        }
        .padding(.vertical, DesignTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(.surface, radius: DesignTokens.radiusLg)
    }

    @ViewBuilder
    private var rowsStack: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { idx, summary in
                ABCampaignRow(summary: summary,
                              forcedHover: forcedHoverIndex == idx,
                              onSelect: onSelect)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if staticRender {
            rowsStack
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { rowsStack }
        }
    }

    private var headerRow: some View {
        HStack(spacing: DesignTokens.space3) {
            // height pinned: a width-only Color.clear is infinitely flexible
            // vertically and makes the header row soak up table height
            Color.clear.frame(width: 3, height: 1)
            header("Campaign", nil).frame(maxWidth: .infinity, alignment: .leading)
            header("Status", 110)
            header("Leads", 64)
            header("Sent", 64)
            header("Replies", 64)
            header("Reply rate", 80)
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

struct ABCampaignRow: View {
    let summary: CampaignSummary
    var forcedHover: Bool = false
    var onSelect: ((CampaignSummary) -> Void)? = nil
    @State private var hovering = false
    private var active: Bool { hovering || forcedHover }

    var body: some View {
        // A real Button (plain style), not onTapGesture — rows are the tab's
        // whole point and must be reachable by Full Keyboard Access/VoiceOver
        // (platform review). Hover styling is unaffected.
        Button(action: { onSelect?(summary) }) {
            HStack(spacing: DesignTokens.space3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DesignTokens.accent)
                    .frame(width: 3, height: active ? 26 : 0)   // marker slides in on hover

                Text(summary.name)
                    .font(.adventor(DesignTokens.textBase, bold: active))
                    .foregroundStyle(active ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ABStatusPill(text: summary.status, role: ABCampaignRoles.campaign(summary.status))
                    .frame(width: 110, alignment: .leading)

                figure(summary.totalLeads, width: 64)
                figure(summary.totalSent, width: 64)
                figure(summary.totalReplies, width: 64,
                       color: summary.totalReplies > 0 ? DesignTokens.accentPink : DesignTokens.textMuted)

                Text(summary.replyRatePercent.map { String(format: "%.1f%%", $0) } ?? "—")
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textMuted)
                    .frame(width: 80, alignment: .leading)
            }
            .padding(.vertical, DesignTokens.space2)
            .padding(.horizontal, DesignTokens.space3)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radiusMd, style: .continuous)
                    .fill(active ? DesignTokens.bgHighlight : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(ABMotion.fast, value: active)
        .onHover { hovering = $0 }
        .pointingCursor
    }

    private func figure(_ n: Int, width: CGFloat, color: Color = DesignTokens.textMuted) -> some View {
        Text(n, format: .number)
            .font(.abMono(DesignTokens.textSm))
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
    }
}
