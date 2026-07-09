import Foundation

/// Deterministically turns lead rows into a `Dashboard` (layout + widget data).
///
/// Widget *data* is derived from live leads here; the *layout* comes from a
/// `LayoutPlan` packed by `Packer` (M2). Pure/synchronous and side-effect free so it's
/// trivially testable and the UI layer stays declarative.
enum DashboardBuilder {

    /// The data series `widgetData` produces — the ONLY binds a plan may reference.
    /// Single source of truth for prompt generation (step C) and bind validation.
    /// Must stay in sync with the keys returned by `widgetData(_:)`.
    static let availableBinds: Set<String> = [
        "total-leads", "by-source", "by-industry", "by-tier", "sentiment-mix",
        "added-weekly", "recent-leads",
    ]

    /// Compose a dashboard from a (cached or LLM-generated) plan + the fetched inputs.
    static func compose(_ inputs: DashboardInputs, plan: LayoutPlan) -> Dashboard {
        Dashboard(layout: Packer.pack(plan), widgets: widgetData(inputs))
    }

    /// Convenience: compose with the deterministic default plan (no LLM). Used by the
    /// selftest's data assertions and as a plain fallback.
    static func build(_ inputs: DashboardInputs) -> Dashboard {
        compose(inputs, plan: DefaultLayout.plan)
    }

    // MARK: - Widget data

    /// The per-widget data keyed by bind id. Tier/sentiment come from supplementary
    /// tables — empty (no data / no RLS) renders an empty board, but the profile gives
    /// them strength "none" so the LLM won't bind them.
    static func widgetData(_ inputs: DashboardInputs) -> [String: WidgetData] {
        let leads = inputs.leads
        // The leads breakdowns are computed over the fetched window; when that window is
        // smaller than the true total, say so in the title (the KPI alone is exact).
        let windowed = inputs.totalCount > leads.count
        let scope = windowed ? " (latest \(leads.count) of \(inputs.totalCount))" : ""
        return [
            "total-leads": totalLeadsKPI(inputs.totalCount),
            "by-source": bySourceBoard(leads, titleSuffix: scope),
            "by-industry": byIndustryBoard(leads, titleSuffix: scope),
            "by-tier": board(title: "Leads by Tier", titleSuffix: "", counts: inputs.tierCounts),
            "sentiment-mix": board(title: "Reply Sentiment", titleSuffix: "", counts: inputs.sentimentCounts),
            "added-weekly": addedWeeklyChart(leads, titleSuffix: scope),
            "recent-leads": recentLeadsTable(leads),
        ]
    }

    private static func totalLeadsKPI(_ total: Int) -> WidgetData {
        .kpi(KpiData(
            title: "Total Leads",
            value: Double(total),
            format: .number,
            previousValue: nil,
            trend: nil,
            trendLabel: nil,
            sparkline: nil
        ))
    }

    private static func bySourceBoard(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        categoricalBoard(leads, title: "Leads by Source", titleSuffix: titleSuffix) { $0.leadSource }
    }

    private static func byIndustryBoard(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        categoricalBoard(leads, title: "Leads by Industry", titleSuffix: titleSuffix) { $0.industry }
    }

    /// Counts grouped by a categorical lead field → a status board (via `board`).
    private static func categoricalBoard(
        _ leads: [LeadRow],
        title: String,
        titleSuffix: String,
        topN: Int = 5,
        value: (LeadRow) -> String?
    ) -> WidgetData {
        var counts: [String: Int] = [:]
        for lead in leads {
            let key = value(lead)?.nilIfEmpty ?? "Unknown"
            counts[key, default: 0] += 1
        }
        return board(title: title, titleSuffix: titleSuffix, counts: counts, topN: topN)
    }

    /// Build a status board from a pre-counted `[label: count]`: largest first, capped at
    /// `topN` (= palette size, so named groups get distinct colors) with the tail
    /// aggregated into a neutral "Other". Shared by source/industry/tier/sentiment.
    private static func board(
        title: String,
        titleSuffix: String,
        counts: [String: Int],
        topN: Int = 5
    ) -> WidgetData {
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let palette = ["green", "blue", "purple", "orange", "red"]
        var groups = sorted.prefix(topN).enumerated().map { index, pair in
            StatusGroup(label: pair.key, count: pair.value, status: palette[index % palette.count])
        }
        if sorted.count > topN {
            let other = sorted.dropFirst(topN).reduce(0) { $0 + $1.value }
            groups.append(StatusGroup(label: "Other", count: other, status: "neutral"))
        }
        return .statusBoard(StatusBoardData(title: title + titleSuffix, groups: groups))
    }

    /// Leads added per ISO week, last 8 weeks present in the data.
    private static func addedWeeklyChart(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone

        // Bucket by start-of-week date; skip rows with no/unparseable timestamp.
        var buckets: [Date: Int] = [:]
        for lead in leads {
            guard let date = DateParse.iso(lead.createdAt) else { continue }
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            guard let weekStart = cal.date(from: comps) else { continue }
            buckets[weekStart, default: 0] += 1
        }

        let label = DateFormatter()
        label.locale = Locale(identifier: "en_US_POSIX")   // stable regardless of system locale
        label.dateFormat = "MMM d"
        label.timeZone = cal.timeZone

        // Zero-fill: walk every consecutive week from first to last present in the data
        // so gap weeks render as real zeros (even x-axis spacing), not collapsed away.
        // The step uses the SAME `cal` that produced the bucket keys above — if the
        // bucketing calendar/timezone ever changes, this stepping must change with it
        // or `buckets[cursor]` lookups would miss and every gap week would read 0.
        guard let first = buckets.keys.min(), let last = buckets.keys.max() else {
            return .chart(ChartData(title: "Leads Added / Week" + titleSuffix, kind: .line, points: []))
        }
        var filled: [(week: Date, count: Int)] = []
        var cursor = first
        while cursor <= last {
            filled.append((cursor, buckets[cursor] ?? 0))
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            cursor = next
        }
        let points = filled.suffix(8).map { ChartPoint(x: label.string(from: $0.week), y: Double($0.count)) }

        return .chart(ChartData(title: "Leads Added / Week" + titleSuffix, kind: .line, points: points))
    }

    /// Most-recent leads (already ordered by created_at desc from the query).
    private static func recentLeadsTable(_ leads: [LeadRow]) -> WidgetData {
        let columns = [
            TableColumn(key: "company", label: "Company", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "industry", label: "Industry", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "source", label: "Source", sortable: nil, format: nil, variant: "badge"),
            TableColumn(key: "stage", label: "Stage", sortable: nil, format: nil, variant: "badge"),
            TableColumn(key: "location", label: "Location", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "added", label: "Added", sortable: nil, format: nil, variant: nil),
        ]
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "MMM d, yyyy"

        let rows: [[String: CellValue]] = leads.prefix(25).map { lead in
            let location = [lead.city, lead.state].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")
            let added = DateParse.iso(lead.createdAt).map { dayFmt.string(from: $0) } ?? "—"
            return [
                "company": .string(lead.companyName?.nilIfEmpty ?? "Unknown"),
                "industry": .string(lead.industry?.nilIfEmpty ?? "—"),
                "source": .string(lead.leadSource?.nilIfEmpty ?? "—"),
                "stage": .string(lead.enrichmentStage?.nilIfEmpty ?? "—"),
                "location": .string(location.isEmpty ? "—" : location),
                "added": .string(added),
            ]
        }
        return .table(TableData(title: "Recent Leads", columns: columns, rows: rows))
    }
}

// MARK: - Helpers

/// Tolerant ISO-8601 timestamp parsing for Postgres `timestamptz` (with/without
/// fractional seconds).
enum DateParse {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso(_ string: String?) -> Date? {
        guard let s = string?.nilIfEmpty else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}

extension String {
    /// Self unless it's empty after trimming, in which case nil.
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
