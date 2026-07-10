import SwiftUI
import Observation

/// P4: the campaign drill-down — pick a campaign on the left, read its
/// funnel + KPIs + full lead roster on the right; roster rows open the
/// shared lead profile. Structural clone of `LeadInspectorView` (HSplitView,
/// tap-to-select, newest-wins generation guard). Strictly read-only.
@MainActor
@Observable
final class CampaignInspectorModel {
    private(set) var selected: CampaignSummary?
    private(set) var roster: [CampaignRosterEntry] = []
    private(set) var rosterTruncated = false
    private(set) var namesDegraded = false
    private(set) var isLoadingRoster = false
    private(set) var message: String?
    private var selectGeneration = 0

    func select(_ summary: CampaignSummary) async {
        selectGeneration += 1
        let generation = selectGeneration
        // Header and roster change together — never the new campaign's name
        // over the old campaign's rows (the P5/S05 dependent-state lesson).
        selected = summary
        roster = []
        rosterTruncated = false
        namesDegraded = false
        message = nil
        isLoadingRoster = true
        defer { if generation == selectGeneration { isLoadingRoster = false } }
        do {
            let repo = CampaignsRepository(client: try SupabaseClient.make())
            let result = try await repo.roster(campaignId: summary.id)
            guard generation == selectGeneration else { return }   // superseded
            roster = result.entries
            rosterTruncated = result.truncated
            namesDegraded = result.namesDegraded
            if result.entries.isEmpty {
                message = "No leads enrolled in this campaign."
            }
        } catch {
            guard generation == selectGeneration else { return }   // superseded
            roster = []
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

struct CampaignInspectorView: View {
    @Bindable var model: CampaignInspectorModel
    let summaries: [CampaignSummary]
    @Environment(ProfilePresenter.self) private var presenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane")
                    .foregroundStyle(.secondary)
                Text("Campaign inspector — click a campaign, then a lead")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.isLoadingRoster { ProgressView().controlSize(.small) }
            }
            HSplitView {
                campaignList
                    .frame(minWidth: 240, maxWidth: 360)
                detail
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
        .padding(14)
    }

    private var campaignList: some View {
        List(summaries, selection: .constant(model.selected?.id)) { summary in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(summary.totalLeads) leads · \(summary.totalSent) sent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: summary.status, style: statusForLabel(summary.status))
            }
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.select(summary) } }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = model.selected {
            // Render from the LIVE summary when it still exists — the 10-min
            // refresh must not let the detail pane disagree with the list row
            // beside it (reliability + semantics reviews). The snapshot is
            // only the fallback for a campaign that vanished from the list.
            let summary = summaries.first { $0.id == selected.id } ?? selected
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(summary.name) — \(summary.status)")
                        .font(.headline)
                    kpiRow(summary)
                    funnel(summary)
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if model.rosterTruncated {
                        Text("Roster paging stopped early — the list below may be incomplete.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if model.namesDegraded {
                        Text("Some lead names couldn't be loaded — affected rows show only what's known.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    rosterList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a campaign to inspect its funnel and roster.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func kpiRow(_ summary: CampaignSummary) -> some View {
        HStack(spacing: 14) {
            kpi("Leads", "\(summary.totalLeads)")
            kpi("Sent", "\(summary.totalSent)")
            kpi("Replies", "\(summary.totalReplies)")
            kpi("Replies / Sent", summary.replyRatePercent.map {
                String(format: "%.1f%%", $0)
            } ?? "—")
        }
    }

    private func kpi(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.ui(11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Text(value)
                .font(.dataMono(15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        }
    }

    /// Canonical-order funnel chips from leadStatusCounts; non-canonical
    /// statuses aggregate into "other" (same rules as CampaignBuilder).
    private func funnel(_ summary: CampaignSummary) -> some View {
        let canonical = CampaignBuilder.statusOrder
        let known = Set(canonical.map(\.key))
        let other = summary.leadStatusCounts
            .filter { !known.contains($0.key.lowercased()) }
            .values.reduce(0, +)
        return HStack(spacing: 8) {
            ForEach(canonical, id: \.key) { entry in
                if let n = summary.leadStatusCounts[entry.key], n > 0 {
                    Badge(text: "\(entry.label) \(n)",
                          style: StatusStyle(rawValue: entry.color) ?? .neutral)
                }
            }
            if other > 0 {
                Badge(text: "Other \(other)", style: .neutral)
            }
        }
    }

    private var rosterList: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(model.roster) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.companyName?.nilIfEmpty
                             ?? entry.email?.nilIfEmpty ?? "Unknown")
                            .font(.ui(12, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                        if let email = entry.email?.nilIfEmpty {
                            Text(email)
                                .font(.ui(11))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Spacer()
                    Badge(text: entry.status?.nilIfEmpty ?? "—",
                          style: statusForLabel(entry.status ?? ""))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    presenter.active = LeadRef(id: entry.leadId,
                                               companyName: entry.companyName,
                                               email: entry.email)
                }
                .background(RoundedRectangle(cornerRadius: Radius.md)
                    .fill(Palette.bgElevated.opacity(0.5)))
            }
        }
    }
}
