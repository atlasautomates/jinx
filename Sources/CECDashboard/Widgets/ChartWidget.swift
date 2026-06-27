import SwiftUI
import Charts

struct ChartWidgetView: View {
    let data: ChartData

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionLabel(data.title)

            // Index-keyed so duplicate x-labels (e.g. two "Jun" buckets) from live
            // data don't collide as Identifiable and silently drop a point.
            Chart(Array(data.points.enumerated()), id: \.offset) { _, point in
                if data.kind == .bar {
                    BarMark(
                        x: .value("Category", point.x),
                        y: .value("Value", point.y)
                    )
                    .foregroundStyle(Palette.accent)
                    .cornerRadius(Radius.xs)
                } else {
                    LineMark(
                        x: .value("Category", point.x),
                        y: .value("Value", point.y)
                    )
                    .foregroundStyle(Palette.accent)
                    // monotone: smooth but never overshoots the data range — counts
                    // can't go negative, so catmullRom's dips below zero would lie.
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Category", point.x),
                        y: .value("Value", point.y)
                    )
                    .foregroundStyle(Palette.accent.opacity(0.12))
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                        .foregroundStyle(Palette.borderDefault)
                    AxisValueLabel()
                        .foregroundStyle(Palette.textMuted)
                }
            }
        }
    }
}
