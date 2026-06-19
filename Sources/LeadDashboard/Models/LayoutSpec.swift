import Foundation

/// Widget kinds the renderer knows how to draw. Matches the registry.
enum WidgetType: String, Codable {
    case kpi
    case chart
    case table
    case statusBoard = "status-board"
}

/// Integer grid placement for one breakpoint.
struct GridRect: Codable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

/// One widget's identity + responsive placement (the LLM-generated part).
struct LayoutWidget: Codable, Identifiable {
    let id: String
    let type: WidgetType
    let layouts: [String: GridRect]   // breakpoint name -> rect
}

/// The full responsive layout spec. This is exactly what `claude -p` will emit
/// in M2; for M0 it's decoded from MockData.
struct LayoutSpec: Codable {
    let breakpoints: [String: Int]    // name -> min width
    let cols: [String: Int]           // name -> column count
    let rowHeight: Double
    let widgets: [LayoutWidget]

    /// Pick the breakpoint whose min-width threshold the available width clears,
    /// preferring the largest. Below all thresholds, falls back to the smallest
    /// *defined* breakpoint (then any defined column key) — never an invented one.
    /// Thresholds should be distinct; equal thresholds break by name for determinism
    /// (Dictionary.sorted is not stable on its own).
    func breakpointName(forWidth width: Double) -> String {
        let sorted = breakpoints.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }
        for (name, threshold) in sorted where width >= Double(threshold) {
            return name
        }
        return sorted.last?.key ?? cols.keys.sorted().first ?? "lg"
    }
}
