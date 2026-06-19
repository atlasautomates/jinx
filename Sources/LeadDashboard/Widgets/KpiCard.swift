import SwiftUI

struct KpiCardView: View {
    let data: KpiData

    /// Neutral for a flat/unknown trend — green is reserved for an actual upward move.
    private var trendStyle: StatusStyle {
        switch data.trend {
        case .up: return .green
        case .down: return .red
        default: return .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionLabel(data.title)

            Text(formatValue(data.value, data.format))
                .font(.dataMono(28, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                if let label = data.trendLabel {
                    Badge(text: label, style: trendStyle)
                }
                Spacer()
                if let values = data.sparkline, values.count > 1 {
                    Sparkline(values: values)
                        .frame(width: 84, height: 28)
                }
            }
        }
    }
}
