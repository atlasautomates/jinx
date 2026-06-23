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

        // Zero-fill: leads 3 weeks apart must produce 4 contiguous weekly points (gaps = 0),
        // not 2 collapsed points.
        let gapLeads: [LeadRow] = [
            LeadRow(id: "g1", companyName: "X", firstName: nil, industry: nil,
                    leadSource: "a", city: nil, state: nil, createdAt: "2026-05-04T00:00:00+00:00"),
            LeadRow(id: "g2", companyName: "Y", firstName: nil, industry: nil,
                    leadSource: "a", city: nil, state: nil, createdAt: "2026-05-25T00:00:00+00:00"),
        ]
        let gapBuilt = DashboardBuilder.build(fetched: gapLeads, totalCount: 2)
        if case .chart(let chart)? = gapBuilt.widgets["added-weekly"] {
            let zeros = chart.points.filter { $0.y == 0 }.count
            if chart.points.count != 4 || zeros != 2 {
                problems.append("builder: zero-fill expected 4 points/2 zeros, got \(chart.points.count) points/\(zeros) zeros")
            }
        } else {
            problems.append("builder: gap chart is not a chart")
        }

        // Packer (M2): an LLM plan must expand to a grid with NO overlaps and every
        // rect in-bounds, at every breakpoint — the "can't make a broken grid" guarantee.
        let plan = LayoutPlan(widgets: [
            PlannedWidget(type: .kpi, bind: "total-leads", size: .small, priority: 1),
            PlannedWidget(type: .kpi, bind: "enriched", size: .small, priority: 2),
            PlannedWidget(type: .statusBoard, bind: "by-source", size: .medium, priority: 3),
            PlannedWidget(type: .chart, bind: "added-weekly", size: .large, priority: 4),
            PlannedWidget(type: .table, bind: "recent-leads", size: .full, priority: 5),
            PlannedWidget(type: .kpi, bind: "total-leads", size: .large, priority: 6), // dup bind
        ])
        let packed = Packer.pack(plan)
        problems.append(contentsOf: validateGrid(packed, label: "packer"))
        if packed.widgets.count != 5 {
            problems.append("packer: expected 5 widgets after dedupe, got \(packed.widgets.count)")
        }
        // A full-width widget must occupy its own row width at lg (span == cols).
        if let table = packed.widgets.first(where: { $0.id == "recent-leads" }),
           let r = table.layouts["lg"], r.w != 12 {
            problems.append("packer: full-size widget should span all 12 lg cols, got \(r.w)")
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

    /// Assert a LayoutSpec is renderable at every breakpoint: each widget has a rect,
    /// each rect in-bounds (0 ≤ x, x+w ≤ cols, w/h ≥ 1), and no two widgets overlap.
    /// Checks the UNION of every breakpoint source (spec.breakpoints, spec.cols, and
    /// each widget's layout keys) so a rect emitted for a breakpoint the spec disagrees
    /// on can't slip past unvalidated, and asserts per-breakpoint rect presence — both
    /// guard against a future packer regression, not just today's output.
    private static func validateGrid(_ spec: LayoutSpec, label: String) -> [String] {
        var problems: [String] = []
        var bps = Set(spec.breakpoints.keys)
        bps.formUnion(spec.cols.keys)
        for w in spec.widgets { bps.formUnion(w.layouts.keys) }

        for bp in bps.sorted() {
            guard let cols = spec.cols[bp] else {
                problems.append("\(label): no cols defined for breakpoint '\(bp)'")
                continue
            }
            var rects: [(id: String, r: GridRect)] = []
            for widget in spec.widgets {
                guard let rect = widget.layouts[bp] else {
                    problems.append("\(label): widget '\(widget.id)' missing rect at \(bp)")
                    continue
                }
                rects.append((widget.id, rect))
            }
            for (id, r) in rects {
                if r.x < 0 || r.y < 0 || r.w < 1 || r.h < 1 {
                    problems.append("\(label): widget '\(id)' has invalid rect at \(bp) (\(r.x),\(r.y),\(r.w),\(r.h))")
                }
                if r.x + r.w > cols {
                    problems.append("\(label): widget '\(id)' overflows \(bp) cols (\(r.x)+\(r.w) > \(cols))")
                }
            }
            for i in rects.indices {
                for j in (i + 1)..<rects.count {
                    if overlaps(rects[i].r, rects[j].r) {
                        problems.append("\(label): '\(rects[i].id)' overlaps '\(rects[j].id)' at \(bp)")
                    }
                }
            }
        }
        return problems
    }

    /// Half-open rectangle intersection on the integer grid.
    private static func overlaps(_ a: GridRect, _ b: GridRect) -> Bool {
        let xOverlap = a.x < b.x + b.w && b.x < a.x + a.w
        let yOverlap = a.y < b.y + b.h && b.y < a.y + a.h
        return xOverlap && yOverlap
    }
}
