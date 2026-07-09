import Foundation

/// Deterministically turns pipeline inputs into a `Dashboard` (mirrors
/// `CampaignBuilder` — fixed layout, no Haiku). `now` is injected so the
/// 7-day KPI window is SelfTest-pinnable.
enum PipelineBuilder {

    /// Canonical color per run/stage status.
    static func statusColor(_ status: String?) -> String {
        switch (status ?? "").lowercased() {
        case "succeeded", "success": return "green"
        case "running": return "blue"
        case "paused_for_review": return "purple"
        case "paused_policy_gate", "paused_after_scrape": return "orange"
        case "failed", "error": return "red"
        case "skipped", "resumed": return "neutral"
        default: return "neutral"
        }
    }

    static func build(_ inputs: PipelineInputs, now: Date = Date()) -> Dashboard {
        var widgets: [String: WidgetData] = [:]
        var planned: [PlannedWidget] = []
        var priority = 0
        func next() -> Int { priority += 1; return priority }

        let runs = inputs.runs

        // ── Headline KPIs ──────────────────────────────────────────────────────
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let recent = runs.filter { (DateParse.iso($0.startedAt) ?? .distantPast) >= weekAgo }
        let finished = runs.filter {
            ["succeeded", "failed"].contains(($0.status ?? "").lowercased())
        }
        let succeeded = finished.filter { ($0.status ?? "").lowercased() == "succeeded" }.count
        let successRate = finished.isEmpty ? 0
            : Double(succeeded) / Double(finished.count) * 100.0
        let attention = runs.filter {
            let s = ($0.status ?? "").lowercased()
            return s == "failed" || s.hasPrefix("paused")
        }.count
        let running = runs.filter { ($0.status ?? "").lowercased() == "running" }.count

        widgets["kpi-runs-7d"] = kpi("Runs (7d)", Double(recent.count), .number)
        widgets["kpi-success"] = kpi("Success Rate", successRate, .percent)
        widgets["kpi-attention"] = kpi("Needs Attention", Double(attention), .number)
        widgets["kpi-running"] = kpi("Running Now", Double(running), .number)
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-runs-7d", size: .small, priority: next()))
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-success", size: .small, priority: next()))
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-attention", size: .small, priority: next()))
        planned.append(PlannedWidget(type: .kpi, bind: "kpi-running", size: .small, priority: next()))

        // ── Latest run: stage funnel + drops breakdown ─────────────────────────
        if let latest = runs.first {
            let stages = inputs.stagesByRun[latest.runId] ?? []
            if !stages.isEmpty {
                widgets["latest-funnel"] = funnelBoard(run: latest, stages: stages)
                planned.append(PlannedWidget(type: .statusBoard, bind: "latest-funnel",
                                             size: .medium, priority: next()))
                if let drops = dropsBoard(run: latest, stages: stages) {
                    widgets["latest-drops"] = drops
                    planned.append(PlannedWidget(type: .statusBoard, bind: "latest-drops",
                                                 size: .medium, priority: next()))
                }
            }
        }

        // ── Recent runs table (full width, last) ───────────────────────────────
        widgets["runs-table"] = runsTable(runs, stagesByRun: inputs.stagesByRun,
                                          partial: inputs.partial)
        planned.append(PlannedWidget(type: .table, bind: "runs-table", size: .full,
                                     priority: next()))

        return Dashboard(layout: Packer.pack(LayoutPlan(widgets: planned)), widgets: widgets)
    }

    // MARK: - Widget builders

    private static func kpi(_ title: String, _ value: Double, _ format: ValueFormat) -> WidgetData {
        .kpi(KpiData(title: title, value: value, format: format,
                     previousValue: nil, trend: nil, trendLabel: nil, sparkline: nil))
    }

    /// Per-stage funnel of the latest run: label "stage 12→9", colored by
    /// stage status, in seq order.
    static func funnelBoard(run: PipelineRunRow, stages: [PipelineStageRow]) -> WidgetData {
        let groups = stages.map { s -> StatusGroup in
            let inN = s.countIn.map(String.init) ?? "–"
            let outN = s.countOut.map(String.init) ?? "–"
            return StatusGroup(label: "\(s.stage ?? "?") \(inN)→\(outN)",
                               count: s.countOut ?? s.countIn ?? 0,
                               status: statusColor(s.status))
        }
        let title = "Latest Run — \(run.vertical ?? "?") [\(run.status ?? "?")]"
        return .statusBoard(StatusBoardData(title: title, groups: groups))
    }

    /// Aggregated drops-by-reason across the latest run's stages (nil when the
    /// run dropped nothing — the widget is omitted rather than shown empty).
    static func dropsBoard(run: PipelineRunRow, stages: [PipelineStageRow]) -> WidgetData? {
        var byReason: [String: Int] = [:]
        for stage in stages {
            for (reason, n) in stage.drops ?? [:] {
                byReason[reason, default: 0] += Int(n)
            }
        }
        guard !byReason.isEmpty else { return nil }
        let palette = ["orange", "red", "purple", "blue", "neutral"]
        let groups = byReason
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .enumerated()
            .map { i, pair in
                StatusGroup(label: pair.key, count: pair.value,
                            status: palette[i % palette.count])
            }
        return .statusBoard(StatusBoardData(title: "Latest Run — Drops by Reason",
                                            groups: groups))
    }

    /// "12m 30s" (or "45s") duration between two ledger timestamps; "—" when
    /// the run hasn't finished or a timestamp is missing/unparseable.
    static func durationText(started: String?, finished: String?) -> String {
        guard let s = DateParse.iso(started), let f = DateParse.iso(finished),
              f >= s else { return "—" }
        let secs = Int(f.timeIntervalSince(s))
        return secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s"
    }

    private static func runsTable(_ runs: [PipelineRunRow],
                                  stagesByRun: [String: [PipelineStageRow]],
                                  partial: Bool) -> WidgetData {
        let columns = [
            TableColumn(key: "run", label: "Run", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "vertical", label: "Vertical", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "kind", label: "Kind", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "status", label: "Status", sortable: nil, format: nil, variant: "badge"),
            TableColumn(key: "started", label: "Started", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "duration", label: "Duration", sortable: nil, format: nil, variant: nil),
            TableColumn(key: "out", label: "Leads Out", sortable: nil, format: nil, variant: nil),
        ]
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "MMM d, HH:mm"

        let rows: [[String: CellValue]] = runs.map { run in
            let started = DateParse.iso(run.startedAt).map { dayFmt.string(from: $0) } ?? "—"
            // "Leads out" = the last stage with a recorded count_out (the
            // furthest the book got — export/create when the run completed).
            let stages = stagesByRun[run.runId] ?? []
            let out = stages.last(where: { $0.countOut != nil })?.countOut
            return [
                "run": .string(String(run.runId.prefix(8))),
                "vertical": .string(run.vertical?.nilIfEmpty ?? "—"),
                "kind": .string(run.kind?.nilIfEmpty ?? "—"),
                "status": .string(run.status?.nilIfEmpty ?? "unknown"),
                "started": .string(started),
                "duration": .string(durationText(started: run.startedAt,
                                                 finished: run.finishedAt)),
                "out": out.map { .number(Double($0)) } ?? .string("—"),
            ]
        }
        let title = partial
            ? "Pipeline Runs (partial data — some rows/stages may be missing)"
            : "Pipeline Runs"
        return .table(TableData(title: title, columns: columns, rows: rows))
    }
}
