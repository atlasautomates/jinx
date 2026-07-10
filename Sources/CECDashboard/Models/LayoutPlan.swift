import Foundation

/// The constrained "layout plan" each tab's builder constructs — semantic choices only
/// (which widgets, emphasis, order), never grid geometry. `Packer` deterministically
/// expands a plan into the `LayoutSpec` the renderer consumes, so a small model
/// cannot produce an invalid grid (overlaps / out-of-bounds are impossible).
struct LayoutPlan: Codable, Equatable {
    let widgets: [PlannedWidget]
}

/// Width emphasis. The packer maps this to a column span per breakpoint;
/// height is derived from the widget type.
enum WidgetSize: String, Codable {
    case small
    case medium
    case large
    case full
}

struct PlannedWidget: Codable, Equatable {
    let type: WidgetType   // a registered renderer widget kind
    let bind: String       // a data-series id the builder can produce (becomes LayoutWidget.id)
    let size: WidgetSize
    let priority: Int      // lower places first (top-left); ties broken by input order
}
