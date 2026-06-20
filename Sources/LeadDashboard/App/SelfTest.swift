import Foundation

/// Headless verification of the decode contract (run with `--selftest`).
/// Exercises the same Codable path `claude -p` output will take in M2.
enum SelfTest {
    static func run() -> Never {
        guard let dash = MockData.dashboard else {
            FileHandle.standardError.write(Data("SELFTEST FAIL: mock dashboard failed to decode\n".utf8))
            exit(1)
        }

        var problems: [String] = []

        // Every layout widget must have matching data and a rect per breakpoint.
        let bps = Set(dash.layout.breakpoints.keys)
        for widget in dash.layout.widgets {
            if dash.widgets[widget.id] == nil {
                problems.append("widget '\(widget.id)' has no data")
            }
            let missing = bps.subtracting(widget.layouts.keys)
            if !missing.isEmpty {
                problems.append("widget '\(widget.id)' missing layouts: \(missing.sorted())")
            }
        }

        // All four widget kinds should be represented in the M0 sample.
        let kinds = Set(dash.widgets.values.map { kindName($0) })
        for expected in ["kpi", "chart", "table", "status-board"] where !kinds.contains(expected) {
            problems.append("missing widget kind: \(expected)")
        }

        // Resilience: one malformed widget must be dropped, not blank the dashboard.
        let layoutJSON = """
        { "breakpoints": {"lg":1200}, "cols": {"lg":12}, "rowHeight": 80,
          "widgets": [ {"id":"a","type":"kpi","layouts":{"lg":{"x":0,"y":0,"w":3,"h":2}}} ] }
        """
        let mixedWidgets = """
        { "a": {"type":"kpi","title":"Good","value":10},
          "b": {"type":"not-a-real-type","title":"Bad"} }
        """
        if let partial = Dashboard.decode(layoutJSON: layoutJSON, widgetsJSON: mixedWidgets) {
            if partial.widgets["a"] == nil { problems.append("resilience: good widget 'a' was dropped") }
            if partial.widgets["b"] != nil { problems.append("resilience: bad widget 'b' was not dropped") }
        } else {
            problems.append("resilience: one bad widget blanked the whole dashboard")
        }

        // Binding: DashboardBuilder turns lead rows into the widget contract.
        let sampleLeads: [LeadRow] = [
            LeadRow(id: "1", companyName: "Acme", firstName: "A", industry: "Auto",
                    leadSource: "gmaps-leads", city: "Tampa", state: "FL", createdAt: "2026-06-10T12:00:00+00:00"),
            LeadRow(id: "2", companyName: "Globex", firstName: "B", industry: "Biotech",
                    leadSource: "sales-nav", city: "Austin", state: "TX", createdAt: "2026-06-12T12:00:00.500+00:00"),
            LeadRow(id: "3", companyName: "Initech", firstName: "C", industry: "Tech",
                    leadSource: "gmaps-leads", city: nil, state: nil, createdAt: nil),
        ]
        let built = DashboardBuilder.build(fetched: sampleLeads, totalCount: 720)
        if Set(built.layout.widgets.map { $0.id }) != ["total-leads", "by-source", "added-weekly", "recent-leads"] {
            problems.append("builder: unexpected widget ids")
        }
        if case .kpi(let kpi)? = built.widgets["total-leads"], kpi.value != 720 {
            problems.append("builder: total-leads KPI should reflect totalCount (got \(kpi.value))")
        }
        if case .statusBoard(let board)? = built.widgets["by-source"] {
            let summed = board.groups.reduce(0) { $0 + $1.count }
            if summed != sampleLeads.count { problems.append("builder: source counts (\(summed)) != lead count") }
        } else {
            problems.append("builder: by-source is not a status board")
        }
        if case .table(let table)? = built.widgets["recent-leads"], table.rows.count != sampleLeads.count {
            problems.append("builder: table row count (\(table.rows.count)) != lead count")
        }
        // The row with nil createdAt must not crash the weekly chart; ≤2 weeks present.
        if case .chart(let chart)? = built.widgets["added-weekly"], chart.points.count > 8 {
            problems.append("builder: chart exceeded 8 buckets")
        }

        let summary = "widgets=\(dash.layout.widgets.count) data=\(dash.widgets.count) kinds=\(kinds.sorted())"
        if problems.isEmpty {
            print("SELFTEST PASS — \(summary)")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("SELFTEST FAIL — \(summary)\n  - \(problems.joined(separator: "\n  - "))\n".utf8))
            exit(1)
        }
    }

    private static func kindName(_ data: WidgetData) -> String {
        switch data {
        case .kpi: return "kpi"
        case .chart: return "chart"
        case .table: return "table"
        case .statusBoard: return "status-board"
        }
    }
}
