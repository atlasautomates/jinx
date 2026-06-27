import Foundation

/// The deterministic fallback layout plan — the single source of truth for "the
/// default arrangement." Used everywhere the LLM isn't available: as the M1/step-B
/// layout, and (step C) as the fail-closed fallback when generation fails. Packs to
/// a KPI + source board + weekly chart across the top, full-width recent-leads below.
enum DefaultLayout {
    static let plan = LayoutPlan(widgets: [
        PlannedWidget(type: .kpi,         bind: "total-leads",  size: .small,  priority: 1),
        PlannedWidget(type: .statusBoard, bind: "by-source",    size: .medium, priority: 2),
        PlannedWidget(type: .chart,       bind: "added-weekly", size: .medium, priority: 3),
        PlannedWidget(type: .table,       bind: "recent-leads", size: .full,   priority: 4),
    ])
}
