import Foundation

/// Deterministically turns lead rows into a `Dashboard` (layout + widget data).
///
/// M1 uses a FIXED layout (the LLM generates the layout in M2); only the widget
/// *data* is derived from live leads here. Pure/synchronous and side-effect free
/// so it's trivially testable and the UI layer stays declarative.
enum DashboardBuilder {

    /// `fetched` = the recent-leads window actually pulled; `totalCount` = exact table
    /// total (may exceed `fetched.count` if the window saturated).
    static func build(fetched leads: [LeadRow], totalCount: Int) -> Dashboard {
        Dashboard(layout: layout(), widgets: widgets(leads: leads, totalCount: totalCount))
    }

    // MARK: - Widget data

    private static func widgets(leads: [LeadRow], totalCount: Int) -> [String: WidgetData] {
        // The breakdown widgets are computed over the fetched window; when that window
        // is smaller than the true total, say so in the title so the source/week
        // figures aren't misread as table-wide (the KPI alone is whole-table exact).
        let windowed = totalCount > leads.count
        let scope = windowed ? " (latest \(leads.count) of \(totalCount))" : ""
        return [
            "total-leads": totalLeadsKPI(totalCount),
            "by-source": bySourceBoard(leads, titleSuffix: scope),
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

    /// Counts by `lead_source`, largest first. Status color cycles for visual variety.
    private static func bySourceBoard(_ leads: [LeadRow], titleSuffix: String = "") -> WidgetData {
        var counts: [String: Int] = [:]
        for lead in leads {
            let key = lead.leadSource?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Unknown"
            counts[key, default: 0] += 1
        }
        let palette = ["green", "blue", "purple", "orange", "red"]
        let groups = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .enumerated()
            .map { index, pair in
                StatusGroup(label: pair.key, count: pair.value,
                            status: palette[index % palette.count])
            }
        return .statusBoard(StatusBoardData(title: "Leads by Source" + titleSuffix, groups: groups))
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

        let points = buckets
            .sorted { $0.key < $1.key }
            .suffix(8)
            .map { ChartPoint(x: label.string(from: $0.key), y: Double($0.value)) }

        return .chart(ChartData(title: "Leads Added / Week" + titleSuffix, kind: .line, points: Array(points)))
    }

    /// Most-recent leads (already ordered by created_at desc from the query).
    private static func recentLeadsTable(_ leads: [LeadRow]) -> WidgetData {
        let columns = [
            TableColumn(key: "company", label: "Company", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "industry", label: "Industry", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "source", label: "Source", sortable: nil, format: nil, variant: "badge"),
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
                "location": .string(location.isEmpty ? "—" : location),
                "added": .string(added),
            ]
        }
        return .table(TableData(title: "Recent Leads", columns: columns, rows: rows))
    }

    // MARK: - Fixed M1 layout (LLM-generated in M2)

    private static func layout() -> LayoutSpec {
        func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> GridRect { GridRect(x: x, y: y, w: w, h: h) }
        return LayoutSpec(
            breakpoints: ["lg": 1200, "md": 996, "sm": 768],
            cols: ["lg": 12, "md": 10, "sm": 6],
            rowHeight: 80,
            widgets: [
                LayoutWidget(id: "total-leads", type: .kpi,
                             layouts: ["lg": r(0, 0, 3, 2), "md": r(0, 0, 5, 2), "sm": r(0, 0, 6, 2)]),
                LayoutWidget(id: "by-source", type: .statusBoard,
                             layouts: ["lg": r(3, 0, 4, 4), "md": r(5, 0, 5, 4), "sm": r(0, 2, 6, 4)]),
                LayoutWidget(id: "added-weekly", type: .chart,
                             layouts: ["lg": r(7, 0, 5, 4), "md": r(0, 2, 5, 4), "sm": r(0, 6, 6, 3)]),
                LayoutWidget(id: "recent-leads", type: .table,
                             layouts: ["lg": r(0, 4, 12, 4), "md": r(0, 6, 10, 4), "sm": r(0, 9, 6, 4)]),
            ]
        )
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
