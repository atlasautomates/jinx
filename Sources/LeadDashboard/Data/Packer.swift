import Foundation

/// Deterministically expands a `LayoutPlan` into a renderer-ready `LayoutSpec`.
///
/// Uses left-to-right, top-to-bottom shelf packing per breakpoint: each widget's
/// column span comes from its size class, it's placed at the current cursor, and the
/// row wraps when the next widget wouldn't fit. This GUARANTEES, by construction:
/// no overlaps, every span within the column count, every widget placed. The LLM
/// only chooses type/bind/size/priority — it can never emit a broken grid.
///
/// Pure and synchronous → trivially testable, no I/O.
enum Packer {
    // Grid geometry — MUST stay in lockstep with the M1 fixed layout
    // (DashboardBuilder.layout) and the renderer's breakpoint/col assumptions.
    // There's no compile-time link; --selftest pins the lg=12 expectation.
    static let breakpoints: [String: Int] = ["lg": 1200, "md": 996, "sm": 768]
    static let cols: [String: Int] = ["lg": 12, "md": 10, "sm": 6]
    static let rowHeight: Double = 80
    private static let order = ["lg", "md", "sm"]

    static func pack(_ plan: LayoutPlan) -> LayoutSpec {
        // Stable priority order (ties → input order), then de-dupe by bind so a
        // repeated bind can't double-place and leave a phantom gap.
        let indexed: [(offset: Int, element: PlannedWidget)] = Array(plan.widgets.enumerated())
        let sorted = indexed.sorted { a, b in
            if a.element.priority != b.element.priority {
                return a.element.priority < b.element.priority
            }
            return a.offset < b.offset
        }
        var seenBind = Set<String>()
        var deduped: [PlannedWidget] = []
        for entry in sorted where seenBind.insert(entry.element.bind).inserted {
            deduped.append(entry.element)
        }

        // Pack each breakpoint independently → rects keyed by bind.
        var rects: [String: [String: GridRect]] = [:]
        for bp in order {
            let colCount = max(cols[bp] ?? 12, 1)
            var x = 0, y = 0, rowMaxH = 0
            for w in deduped {
                let span = min(max(self.span(w.size, bp), 1), colCount)
                let h = max(height(w.type), 1)
                if x + span > colCount {       // doesn't fit → wrap to next shelf
                    y += rowMaxH
                    x = 0
                    rowMaxH = 0
                }
                rects[w.bind, default: [:]][bp] = GridRect(x: x, y: y, w: span, h: h)
                x += span
                rowMaxH = max(rowMaxH, h)
            }
        }

        let widgets: [LayoutWidget] = deduped.compactMap { w in
            guard let layouts = rects[w.bind] else { return nil }
            return LayoutWidget(id: w.bind, type: w.type, layouts: layouts)
        }
        return LayoutSpec(breakpoints: breakpoints, cols: cols, rowHeight: rowHeight, widgets: widgets)
    }

    // MARK: - Size → span, type → height

    /// Column span for a size class at a breakpoint (12 / 10 / 6 cols for lg / md / sm).
    /// Intentional size-class collapse at narrow breakpoints: at md, small==medium (5)
    /// and large==full (10); at sm, medium/large/full all == 6 (full width). So some
    /// of the LLM's size emphasis is deliberately flattened on smaller windows.
    private static func span(_ size: WidgetSize, _ bp: String) -> Int {
        switch size {
        case .small:  return bp == "lg" ? 3 : (bp == "md" ? 5 : 3)
        case .medium: return bp == "lg" ? 4 : (bp == "md" ? 5 : 6)
        case .large:  return bp == "lg" ? 6 : (bp == "md" ? 10 : 6)
        case .full:   return bp == "lg" ? 12 : (bp == "md" ? 10 : 6)
        }
    }

    /// Row height (in grid rows) by widget type — KPIs are short, content widgets tall.
    private static func height(_ type: WidgetType) -> Int {
        switch type {
        case .kpi: return 2
        case .table, .chart, .statusBoard: return 4
        }
    }
}
