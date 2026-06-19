import SwiftUI

/// Wraps a widget's content in the standard Card chrome and dispatches on type.
/// This is the SwiftUI analog of the template's widget-registry: WidgetData -> view.
struct WidgetWrapper: View {
    let data: WidgetData

    var body: some View {
        Card {
            switch data {
            case .kpi(let d): KpiCardView(data: d)
            case .chart(let d): ChartWidgetView(data: d)
            case .table(let d): DataTableView(data: d)
            case .statusBoard(let d): StatusBoardView(data: d)
            }
        }
    }
}
