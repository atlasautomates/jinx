import Foundation

/// Deterministically turns campaign inputs into a `Dashboard` (layout + widget data).
/// Mirrors `DashboardBuilder`, but builds the `LayoutPlan` itself (one funnel board per
/// campaign) rather than going through the Haiku layout engine — the campaigns MVP uses
/// a fixed, deterministic layout. (Adaptive layout via `LayoutEngine` is a later add-on.)
enum CampaignBuilder {

    /// Canonical funnel order + color for campaign_leads.status values.
    private static let statusOrder: [(key: String, label: String, color: String)] = [
        ("pending", "Pending", "blue"),
        ("sent", "Sent", "green"),
        ("replied", "Replied", "purple"),
        ("bounced", "Bounced", "orange"),
        ("unsubscribed", "Unsubscribed", "red"),
    ]

    static func build(_ inputs: CampaignInputs) -> Dashboard {
        var widgets: [String: WidgetData] = [:]
        var planned: [PlannedWidget] = []
        var priority = 0
        func next() -> Int { priority += 1; return priority }

        // ── Headline KPIs (aggregate) ──────────────────────────────────────────
        let summaries = inputs.summaries
        let active = summaries.filter { $0.status.lowercased() == "active" }.count
        let totalSent = summaries.reduce(0) { $0 + $1.totalSent }
        let totalReplies = summaries.reduce(0) { $0 + $1.totalReplies }
        // Replies ÷ emails-sent. This is the dashboard's own definition (per-sent);
        // distinct from campaigns_tracking.reply_rate (replies ÷ delivered), which we do
        // NOT surface here — labeled "Replies / Sent" so the two can't be conflated.
        let replyRate = totalSent > 0 ? Double(totalReplies) / Double(totalSent) * 100.0 : 0

        widgets["kpi-active"] = kpi("Active Campaigns", Double(active), .number)
        widgets["kpi-sent"] = kpi("Emails Sent", Double(totalSent), .number)
        widgets["kpi-replies"] = kpi("Replies", Double(totalReplies), .number)
        widgets["kpi-reply-rate"] = kpi("Replies / Sent", replyRate, .percent)
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-active", size: .small, priority: next()))
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-sent", size: .small, priority: next()))
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-replies", size: .small, priority: next()))
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-reply-rate", size: .small, priority: next()))

        // ── Sends by sending account (aggregate) ───────────────────────────────
        if !inputs.sendsByAccount.isEmpty {
            widgets["by-account"] = accountBoard(inputs.sendsByAccount)
            planned.append(PlannedWidget(type: .statusBoard, bind: "by-account", size: .medium, priority: next()))
        }

        // ── One delivery-funnel board per campaign that has a roster ────────────
        for summary in summaries where !summary.leadStatusCounts.isEmpty {
            let bind = "funnel-\(summary.id)"
            widgets[bind] = funnelBoard(summary)
            planned.append(PlannedWidget(type: .statusBoard, bind: bind, size: .medium, priority: next()))
        }

        // ── Per-campaign metrics table (full width, last) ───────────────────────
        widgets["campaigns-table"] = campaignsTable(summaries, partial: inputs.partial)
        planned.append(PlannedWidget(type: .table, bind: "campaigns-table", size: .full, priority: next()))

        return Dashboard(layout: Packer.pack(LayoutPlan(widgets: planned)), widgets: widgets)
    }

    // MARK: - Widget builders

    private static func kpi(_ title: String, _ value: Double, _ format: ValueFormat) -> WidgetData {
        .kpi(KpiData(title: title, value: value, format: format,
                     previousValue: nil, trend: nil, trendLabel: nil, sparkline: nil))
    }

    /// Delivery funnel for one campaign, in canonical status order (only statuses present).
    private static func funnelBoard(_ s: CampaignSummary) -> WidgetData {
        var groups: [StatusGroup] = statusOrder.compactMap { entry in
            guard let count = s.leadStatusCounts[entry.key], count > 0 else { return nil }
            return StatusGroup(label: entry.label, count: count, status: entry.color)
        }
        // Any non-canonical statuses (e.g. "unknown") roll into a neutral group.
        let known = Set(statusOrder.map { $0.key })
        let otherCount = s.leadStatusCounts.filter { !known.contains($0.key) }.values.reduce(0, +)
        if otherCount > 0 { groups.append(StatusGroup(label: "Other", count: otherCount, status: "neutral")) }
        let title = "\(s.name) — \(s.totalLeads) lead\(s.totalLeads == 1 ? "" : "s")"
        return .statusBoard(StatusBoardData(title: title, groups: groups))
    }

    private static func accountBoard(_ byAccount: [String: Int]) -> WidgetData {
        let palette = ["green", "blue", "purple", "orange", "red"]
        let sorted = byAccount.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let groups = sorted.enumerated().map { i, pair in
            // Short-form the account for the label (local-part before @).
            let label = pair.key.split(separator: "@").first.map(String.init) ?? pair.key
            return StatusGroup(label: label, count: pair.value, status: palette[i % palette.count])
        }
        return .statusBoard(StatusBoardData(title: "Sends by Account", groups: groups))
    }

    private static func campaignsTable(_ summaries: [CampaignSummary], partial: Bool) -> WidgetData {
        let columns = [
            TableColumn(key: "campaign", label: "Campaign", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "status", label: "Status", sortable: nil, format: nil, variant: "badge"),
            TableColumn(key: "leads", label: "Leads", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "sent", label: "Sent", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "replies", label: "Replies", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "reply_rate", label: "Reply %", sortable: nil, format: nil, variant: nil),
        ]
        let rows: [[String: CellValue]] = summaries.map { s in
            let rr = s.replyRatePercent.map { String(format: "%.1f%%", $0) } ?? "—"
            return [
                "campaign": .string(s.name),
                "status": .string(s.status.capitalized),
                "leads": .number(Double(s.totalLeads)),
                "sent": .number(Double(s.totalSent)),
                "replies": .number(Double(s.totalReplies)),
                "reply_rate": .string(rr),
            ]
        }
        // Honest signal when a read failed or a window truncated — the numbers below may
        // under-report, so say so rather than presenting them as authoritative.
        let title = partial ? "Campaigns (partial data — some metrics may be incomplete)" : "Campaigns"
        return .table(TableData(title: title, columns: columns, rows: rows))
    }
}
