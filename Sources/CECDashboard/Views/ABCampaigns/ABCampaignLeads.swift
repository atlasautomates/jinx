import SwiftUI

// Drill level 2: one campaign's leads. KPI strip + funnel chips are supporting
// context (brief §2 — the lead rows are the focus); row tap → correspondence.

struct ABCampaignLeadsView: View {
    let summary: CampaignSummary
    let drill: CampaignDrillModel
    var staticRender: Bool = false
    var forcedHoverIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            context
            captions
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Supporting context (KPIs + funnel)

    private var context: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space5) {
            ABStatusPill(text: summary.status, role: ABCampaignRoles.campaign(summary.status))
            kpi(summary.totalLeads, "leads", DesignTokens.textSecondary)
            kpi(summary.totalSent, "sent", DesignTokens.accent)
            kpi(summary.totalReplies, "replies", DesignTokens.accentPink)
            Text(summary.replyRatePercent.map { String(format: "%.1f%% reply rate", $0) }
                 ?? "no sends yet")
                .font(.abMono(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
            Spacer()
            funnelChips
        }
    }

    private func kpi(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space1) {
            Text(n, format: .number)
                .font(.abMono(DesignTokens.textBase, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
        }
    }

    /// Canonical funnel order + "Other" rollup — the vocabulary the old
    /// dashboard funnel used, now as compact pills.
    static let funnelOrder: [(key: String, label: String)] = [
        ("pending", "Pending"), ("sent", "Sent"), ("replied", "Replied"),
        ("bounced", "Bounced"), ("unsubscribed", "Unsub"),
    ]

    /// Pure seam (SelfTest target): canonical statuses in order (zero-count
    /// dropped), non-canonical rolled into "Other". Input keys are case-folded
    /// ONCE at entry so the canonical lookup and the Other rollup can never
    /// disagree (QA: `["Sent": 3]` previously vanished from both).
    static func funnelEntries(_ counts: [String: Int]) -> [(label: String, count: Int, role: ABStatusRole)] {
        let folded = Dictionary(counts.map { ($0.key.lowercased(), $0.value) },
                                uniquingKeysWith: +)
        let known = Set(funnelOrder.map(\.key))
        var entries: [(String, Int, ABStatusRole)] = funnelOrder.compactMap { entry in
            guard let n = folded[entry.key], n > 0 else { return nil }
            return (entry.label, n, ABCampaignRoles.rosterLead(entry.key))
        }
        let other = folded.filter { !known.contains($0.key) }.values.reduce(0, +)
        if other > 0 { entries.append(("Other", other, .neutral)) }
        return entries
    }

    private var funnelChips: some View {
        HStack(spacing: DesignTokens.space2) {
            ForEach(Self.funnelEntries(summary.leadStatusCounts), id: \.label) { entry in
                ABStatusPill(text: "\(entry.label) \(entry.count)", role: entry.role)
            }
        }
    }

    // MARK: Honesty captions

    @ViewBuilder
    private var captions: some View {
        if drill.rosterTruncated {
            ABDegradedCaption(text: "Roster paging stopped early — this list may be incomplete.")
        }
        if drill.namesDegraded {
            ABDegradedCaption(text: "Some lead names couldn't be loaded — affected rows show only what's known.")
        }
    }

    // MARK: The leads table

    @ViewBuilder
    private var table: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(spacing: DesignTokens.space2) {
                ABSectionLabel("Leads in campaign")
                Text("(\(drill.roster.count))")
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
                if drill.isLoadingRoster {
                    ProgressView().controlSize(.small).tint(DesignTokens.accent)
                }
                Spacer()
                Text("click a lead for correspondence")
                    .font(.adventor(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
            }
            .padding(.horizontal, DesignTokens.space3)

            headerRow.padding(.horizontal, DesignTokens.space3)

            if let message = drill.rosterMessage {
                Text(message)
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
            ForEach(Array(drill.roster.enumerated()), id: \.element.id) { idx, entry in
                ABCampaignLeadRow(entry: entry,
                                  forcedHover: forcedHoverIndex == idx,
                                  onSelect: { entry in Task { await drill.openLead(entry) } })
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
            header("Company", 230)
            header("Email", nil).frame(maxWidth: .infinity, alignment: .leading)
            header("Status", 110)
            header("Added", 100)
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

struct ABCampaignLeadRow: View {
    let entry: CampaignRosterEntry
    var forcedHover: Bool = false
    var onSelect: ((CampaignRosterEntry) -> Void)? = nil
    @State private var hovering = false
    private var active: Bool { hovering || forcedHover }

    private var status: String { entry.status?.nilIfEmpty ?? "—" }

    var body: some View {
        // Real Button for keyboard/VoiceOver reachability (platform review).
        Button(action: { onSelect?(entry) }) {
            HStack(spacing: DesignTokens.space3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ABCampaignRoles.rosterLead(status) == .reward
                          ? DesignTokens.accentPink : DesignTokens.accent)
                    .frame(width: 3, height: active ? 26 : 0)

                Text(entry.companyName?.nilIfEmpty ?? "Unknown")
                    .font(.adventor(DesignTokens.textBase, bold: active))
                    .foregroundStyle(active ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                    .lineLimit(1)
                    .frame(width: 230, alignment: .leading)

                Text(entry.email?.nilIfEmpty ?? "—")
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ABStatusPill(text: status, role: ABCampaignRoles.rosterLead(status))
                    .frame(width: 110, alignment: .leading)

                Text(Self.shortDate(entry.addedAt))
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(active ? DesignTokens.textSecondary : DesignTokens.textGhost)
                    .frame(width: 100, alignment: .leading)
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

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        // POSIX locale pins the fixed format (platform review).
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// ISO timestamp → "Jun 12, 2026"; unparseable/absent → "—".
    static func shortDate(_ iso: String?) -> String {
        DateParse.iso(iso).map { dayFmt.string(from: $0) } ?? "—"
    }
}
