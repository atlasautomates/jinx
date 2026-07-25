import Foundation

/// Deterministically turns lead rows into a `Dashboard` (layout + widget data).
/// Builds its own `LayoutPlan` inline (like `CampaignBuilder`/`PipelineBuilder`) —
/// the Haiku layout engine was removed (P1 renovation): same data now always
/// renders the same arrangement. Pure/synchronous and side-effect free.
enum DashboardBuilder {

    /// The data series `widgetData` produces. Kept as a drift guard: the selftest
    /// asserts these match `widgetData(_:)`'s keys exactly.
    static let availableBinds: Set<String> = [
        "by-source", "by-industry", "by-status", "by-tier", "sentiment-mix",
        "added-weekly",
    ]

    /// Hand-designed fixed layout. Supplementary boards (tier/sentiment) appear
    /// only when their table returned data — an empty board is noise, not signal.
    /// (The recent-leads table left the grid in P3 and now lives in the
    /// ABLeads surface; this builder currently serves selftest/packer only.)
    static func build(_ inputs: DashboardInputs) -> Dashboard {
        var planned: [PlannedWidget] = []
        var priority = 0
        func next() -> Int { priority += 1; return priority }

        // The total-leads KPI left the grid (i-9f08): the exact total now renders as subtext
        // under the tab title (RootView passes it into DashboardShell's subtitle).
        planned.append(PlannedWidget(type: .statusBoard, bind: "by-source", size: .medium, priority: next()))
        planned.append(PlannedWidget(type: .statusBoard, bind: "by-industry", size: .medium, priority: next()))
        planned.append(PlannedWidget(type: .statusBoard, bind: "by-status", size: .medium, priority: next()))
        if !inputs.tierCounts.isEmpty {
            planned.append(PlannedWidget(type: .statusBoard, bind: "by-tier", size: .medium, priority: next()))
        }
        if !inputs.sentimentCounts.isEmpty {
            planned.append(PlannedWidget(type: .statusBoard, bind: "sentiment-mix", size: .medium, priority: next()))
        }
        planned.append(PlannedWidget(type: .chart, bind: "added-weekly", size: .large, priority: next()))

        return Dashboard(layout: Packer.pack(LayoutPlan(widgets: planned)),
                         widgets: widgetData(inputs))
    }

    // MARK: - Widget data

    /// The per-widget data keyed by bind id. Tier/sentiment come from supplementary
    /// tables — empty (no data / no RLS) renders an empty board (and `build` skips
    /// planning it).
    static func widgetData(_ inputs: DashboardInputs) -> [String: WidgetData] {
        let leads = inputs.leads
        // The leads breakdowns are computed over the fetched window; when that window is
        // smaller than the true total, say so in the title (the toolbar subtitle total is exact).
        let windowed = inputs.totalCount > leads.count
        let scope = windowed ? " (latest \(leads.count) of \(inputs.totalCount))" : ""
        // The partial (degraded supplementary read) signal rides the chart title
        // now that the recent-leads table left the grid (P3).
        let partialNote = inputs.partial
            ? " (partial data — some breakdowns may be missing)" : ""
        // by-status prefers the EXACT full-table counts (a recency window skews a pipeline-stage
        // distribution toward "scraped"); when that supplementary read failed, fall back to the
        // windowed rollup with the honest scope suffix — the board never vanishes.
        let statusBoard = inputs.statusCounts.isEmpty
            ? byStatusBoard(leads, titleSuffix: scope)
            : board(title: "Leads by Status", titleSuffix: "",
                    counts: Dictionary(uniqueKeysWithValues: inputs.statusCounts.map { (stageLabel($0.key), $0.value) }))
        return [
            "by-source": bySourceBoard(leads, titleSuffix: scope),
            "by-industry": byIndustryBoard(leads, titleSuffix: scope),
            "by-status": statusBoard,
            "by-tier": board(title: "Leads by Tier", titleSuffix: "", counts: inputs.tierCounts),
            "sentiment-mix": board(title: "Reply Sentiment", titleSuffix: "", counts: inputs.sentimentCounts),
            "added-weekly": addedWeeklyChart(leads, titleSuffix: scope + partialNote),
        ]
    }

    private static func bySourceBoard(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        categoricalBoard(leads, title: "Leads by Source", titleSuffix: titleSuffix) { $0.leadSource }
    }

    private static func byIndustryBoard(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        categoricalBoard(leads, title: "Leads by Industry", titleSuffix: titleSuffix) { $0.industry }
    }

    /// Locale-stable display casing for a stage token ("scraped" → "Scraped") — POSIX-pinned,
    /// matching this file's DateFormatter precedent, so a Turkish-locale run can't retitle a bucket.
    private static func stageLabel(_ stage: String) -> String {
        stage.capitalized(with: Locale(identifier: "en_US_POSIX"))
    }

    /// WINDOWED fallback for the status board (used only when the exact full-table counts are
    /// unavailable): pipeline position (`enrichment_stage`) bucketed over the fetched window,
    /// capitalized for display; rows without a stage fall to categoricalBoard's "Unknown".
    private static func byStatusBoard(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        categoricalBoard(leads, title: "Leads by Status", titleSuffix: titleSuffix) { $0.enrichmentStage.map(stageLabel) }
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
