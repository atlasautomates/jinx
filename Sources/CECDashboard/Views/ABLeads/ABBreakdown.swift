import SwiftUI

// LEVEL 3: three breakdowns — by source, industry, status. Horizontal bars,
// width proportional to the panel max. Source/industry use teal; status colors
// each bar by its role (teal/pink/neutral/warn — decision-log #5).

struct ABBreakdownPanel: View {
    let title: String
    let items: [ABLeadsData.Breakdown]
    /// Per-row bar color; nil -> teal accent for every row.
    var colorFor: ((String) -> Color)? = nil
    /// Force one row's hover state for the interaction-demo preview.
    var forcedHoverLabel: String? = nil

    private var maxCount: Int { items.map(\.count).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            ABSectionLabel(title)
            VStack(spacing: DesignTokens.space2) {
                ForEach(items) { item in
                    ABBreakdownRow(label: item.label, count: item.count,
                                   fraction: CGFloat(item.count) / CGFloat(maxCount),
                                   color: colorFor?(item.label) ?? DesignTokens.accent,
                                   forcedHover: forcedHoverLabel == item.label)
                }
            }
        }
        .padding(DesignTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(.surface, radius: DesignTokens.radiusLg)
    }
}

private struct ABBreakdownRow: View {
    let label: String
    let count: Int
    let fraction: CGFloat
    let color: Color
    var forcedHover: Bool = false

    @State private var hovering = false
    private var active: Bool { hovering || forcedHover }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space1) {
            HStack {
                Text(label)
                    .font(.adventor(DesignTokens.textSm, bold: active))
                    .foregroundStyle(active ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(count, format: .number)
                    .font(.abMono(DesignTokens.textSm, weight: .semibold))
                    .foregroundStyle(active ? color : DesignTokens.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignTokens.bgRoot)
                    Capsule()
                        .fill(LinearGradient(
                            colors: active ? [color, color] : [color.opacity(0.85), color.opacity(0.55)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * fraction))
                        .shadow(color: active ? color.opacity(0.5) : .clear, radius: 5)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, DesignTokens.space1)
        .padding(.horizontal, DesignTokens.space2)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusSm, style: .continuous)
                .fill(active ? DesignTokens.bgHighlight : Color.clear))
        .contentShape(Rectangle())
        .animation(ABMotion.fast, value: active)
        .onHover { hovering = $0 }
    }
}

struct ABBreakdownRowGroup: View {
    let data: ABLeadsData
    var forcedHoverStatusLabel: String? = nil

    private func statusColor(_ label: String) -> Color {
        switch ABStatusRole(label) {
        case .reward:  return DesignTokens.accentPink
        case .active:  return DesignTokens.accent
        case .warn:    return DesignTokens.statusRedText
        case .neutral: return DesignTokens.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.space5) {
            ABBreakdownPanel(title: "By source", items: data.bySource)
                .frame(maxWidth: .infinity)
            ABBreakdownPanel(title: "By industry", items: data.byIndustry)
                .frame(maxWidth: .infinity)
            ABBreakdownPanel(title: "By status", items: data.byStatus,
                             colorFor: statusColor, forcedHoverLabel: forcedHoverStatusLabel)
                .frame(maxWidth: .infinity)
        }
    }
}
