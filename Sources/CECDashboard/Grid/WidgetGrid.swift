import SwiftUI

/// Renders the layout spec into an absolutely-placed responsive grid.
///
/// v0 honors the spec's explicit `(x, y, w, h)` placement for the active
/// breakpoint (the template provides these for every breakpoint, so we get the
/// "v1" free-grid behaviour for free). The caller supplies `width`; the grid
/// computes its own intrinsic height so it sits cleanly inside a ScrollView.
struct WidgetGrid: View {
    let layout: LayoutSpec
    let widgets: [String: WidgetData]
    let width: CGFloat

    private let gap = Space.s4

    var body: some View {
        let bp = layout.breakpointName(forWidth: Double(width))
        let cols = max(layout.cols[bp] ?? 12, 1)
        let rowH = CGFloat(layout.rowHeight)
        // Floor at 1pt: the grid defends its own inputs rather than relying on a
        // caller's minimum window width (gutters can exceed width at tiny sizes).
        let colW = max((width - gap * CGFloat(cols - 1)) / CGFloat(cols), 1)

        // Resolve + sanitize each placed widget for the active breakpoint, so
        // degenerate plan geometry can't render silently broken tiles.
        let placed: [Placed] = layout.widgets.compactMap { widget in
            guard let rect = widget.layouts[bp], let data = widgets[widget.id] else { return nil }
            return Placed(id: widget.id, rect: Self.sanitize(rect, cols: cols), data: data)
        }
        let totalRows = placed.map { $0.rect.y + $0.rect.h }.max() ?? 0
        let contentHeight = CGFloat(totalRows) * (rowH + gap)

        ZStack(alignment: .topLeading) {
            ForEach(placed) { item in
                WidgetWrapper(data: item.data)
                    .frame(
                        width: colW * CGFloat(item.rect.w) + gap * CGFloat(item.rect.w - 1),
                        height: rowH * CGFloat(item.rect.h) + gap * CGFloat(item.rect.h - 1)
                    )
                    .offset(
                        x: CGFloat(item.rect.x) * (colW + gap),
                        y: CGFloat(item.rect.y) * (rowH + gap)
                    )
            }
        }
        .frame(width: width, height: contentHeight, alignment: .topLeading)
    }

    private struct Placed: Identifiable {
        let id: String
        let rect: GridRect
        let data: WidgetData
    }

    /// Clamp a rect to safe bounds: on-grid origin, span ≥ 1, width ≤ column count.
    private static func sanitize(_ r: GridRect, cols: Int) -> GridRect {
        GridRect(
            x: min(max(r.x, 0), max(cols - 1, 0)),
            y: max(r.y, 0),
            w: min(max(r.w, 1), cols),
            h: max(r.h, 1)
        )
    }
}
