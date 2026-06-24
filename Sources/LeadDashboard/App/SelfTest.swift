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

        // DataProfile (M2 step B): key is deterministic, stable to small changes,
        // and shifts when the data character changes.
        let leadsA: [LeadRow] = [
            LeadRow(id: "1", companyName: "A", firstName: nil, industry: "Auto",
                    leadSource: "gmaps-leads", city: "Tampa", state: "FL", createdAt: "2026-06-10T00:00:00+00:00"),
            LeadRow(id: "2", companyName: "B", firstName: nil, industry: "Biotech",
                    leadSource: "sales-nav", city: "Austin", state: "TX", createdAt: "2026-06-12T00:00:00+00:00"),
        ]
        let p1 = DataProfile.from(leads: leadsA, totalCount: 300)
        let p1again = DataProfile.from(leads: leadsA, totalCount: 300)
        if p1.key != p1again.key { problems.append("profile: key not deterministic") }
        if p1.key.isEmpty { problems.append("profile: key is empty") }
        // Adding one lead (still same buckets) must NOT change the key.
        let p1plus = DataProfile.from(leads: leadsA, totalCount: 301)
        if p1.key != p1plus.key { problems.append("profile: key over-sensitive to a tiny change") }
        // Crossing a magnitude bucket (300→5000) MUST change the key.
        let p2 = DataProfile.from(leads: leadsA, totalCount: 5000)
        if p1.key == p2.key { problems.append("profile: key didn't shift across a magnitude bucket") }
        // A non-magnitude signal must also move the key: 4 distinct sources (by-source
        // high) vs leadsA's 2 (medium), same total.
        let leads4src = (0..<4).map { i in
            LeadRow(id: "s\(i)", companyName: "C", firstName: nil, industry: "X",
                    leadSource: "src-\(i)", city: nil, state: nil, createdAt: nil)
        }
        if DataProfile.from(leads: leads4src, totalCount: 300).key == p1.key {
            problems.append("profile: a non-magnitude (by-source) shift didn't change the key")
        }

        // availableBinds must match exactly what widgetData produces (drift guard).
        let dataKeys = Set(DashboardBuilder.widgetData(fetched: sampleLeads, totalCount: 720).keys)
        if dataKeys != DashboardBuilder.availableBinds {
            problems.append("builder: availableBinds \(DashboardBuilder.availableBinds) != widgetData keys \(dataKeys)")
        }

        // sanitize (step C bind-validation): valid plan passes; nil/empty/unknown-bind → default.
        let knownBinds = DashboardBuilder.availableBinds
        if LayoutResolver.sanitize(DefaultLayout.plan, knownBinds: knownBinds) != DefaultLayout.plan {
            problems.append("sanitize: a valid default plan should pass through")
        }
        if LayoutResolver.sanitize(nil, knownBinds: knownBinds) != DefaultLayout.plan {
            problems.append("sanitize: nil should fall back to default")
        }
        if LayoutResolver.sanitize(LayoutPlan(widgets: []), knownBinds: knownBinds) != DefaultLayout.plan {
            problems.append("sanitize: empty plan should fall back to default")
        }
        let badBind = LayoutPlan(widgets: [PlannedWidget(type: .kpi, bind: "hallucinated", size: .small, priority: 1)])
        if LayoutResolver.sanitize(badBind, knownBinds: knownBinds) != DefaultLayout.plan {
            problems.append("sanitize: unknown bind should fall back to default (cache-poison guard)")
        }

        // LayoutEngine.parsePlan: envelope unwrap + fence stripping.
        let goodEnvelope = #"{"is_error":false,"result":"```json\n{\"widgets\":[{\"type\":\"kpi\",\"bind\":\"total-leads\",\"size\":\"small\",\"priority\":1}]}\n```"}"#
        if LayoutEngine.parsePlan(fromEnvelope: goodEnvelope)?.widgets.first?.bind != "total-leads" {
            problems.append("engine: failed to parse a fenced plan from the envelope")
        }
        if LayoutEngine.parsePlan(fromEnvelope: #"{"is_error":true,"result":"refused"}"#) != nil {
            problems.append("engine: an is_error envelope should yield nil")
        }
        if LayoutEngine.parsePlan(fromEnvelope: "not json at all") != nil {
            problems.append("engine: non-JSON envelope should yield nil")
        }

        // LayoutCache round-trip + LayoutResolver gate (async), in a throwaway temp dir.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("LeadDashboardSelfTest", isDirectory: true)
        LayoutCache.clear(in: tmp)
        let counter = Counter()
        let gen: (DataProfile) async -> LayoutPlan? = { _ in counter.bump(); return DefaultLayout.plan }
        func resolve(_ p: DataProfile, force: Bool) {
            _ = runSync { await LayoutResolver.resolvePlan(profile: p, force: force, cacheDir: tmp, generate: gen) }
        }
        resolve(p1, force: false)   // miss → generate
        if counter.value != 1 { problems.append("resolver: first call should generate (n=\(counter.value))") }
        resolve(p1, force: false)   // hit → reuse
        if counter.value != 1 { problems.append("resolver: unchanged profile should reuse cache (n=\(counter.value))") }
        resolve(p1, force: true)    // force → regenerate
        if counter.value != 2 { problems.append("resolver: force should bypass cache (n=\(counter.value))") }
        resolve(p2, force: false)   // changed → regenerate
        if counter.value != 3 { problems.append("resolver: changed profile should regenerate (n=\(counter.value))") }
        if LayoutCache.load(from: tmp)?.key != p2.key { problems.append("cache: did not persist the latest key") }
        LayoutCache.clear(in: tmp)

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

    /// Run an async operation to completion from the synchronous selftest (the resolver
    /// is async now). The body runs off the main thread, so blocking here is safe.
    private static func runSync<T>(_ body: @escaping () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { box.value = await body(); sem.signal() }
        sem.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: T? }
}

/// A tiny thread-safe call counter for the resolver gate test.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
