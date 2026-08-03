import SwiftUI

// LEVEL 2: two weekly time-series. Teal = leads added (primary), pink = leads
// messaged (reward role). Built fresh on tokens (bible §7) — no chart lib.

struct ABTrendChart: View {
    enum Role { case teal, pink }
    let title: String
    let weeks: [String]
    let values: [Int]
    let role: Role
    /// Window-wide total, when summing the buckets would NOT give it. The messaged
    /// series counts distinct leads PER WEEK, so its sum is lead-weeks: a lead
    /// messaged in three weeks would read as three leads under a chart titled
    /// "Leads messaged". nil → the sum is the honest total (leads added).
    var distinctTotal: Int? = nil
    /// Names what the total counts when it isn't simply "leads".
    var totalLabel: String = "total"

    @State private var hovering = false

    private var accent: Color { role == .teal ? DesignTokens.accent : DesignTokens.accentPink }
    private var accentStrong: Color { role == .teal ? DesignTokens.accentStrong : DesignTokens.accentPinkStrong }
    private var accentBorder: Color { role == .teal ? DesignTokens.accentBorder : DesignTokens.accentPinkBorder }

    private var latest: Int { values.last ?? 0 }
    private var total: Int { distinctTotal ?? values.reduce(0, +) }
    // max(1, …) guards the all-zero / empty series: `peak` is the plot's divisor
    // (maxV below), so a 0 here would make every plotted y NaN. Never divides by zero.
    private var peak: Int { max(1, values.max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: DesignTokens.space2) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    ABSectionLabel(title)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space1) {
                    Text(latest, format: .number)
                        .font(.abMono(DesignTokens.textLg, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("this wk").font(.adventor(DesignTokens.textXs)).foregroundStyle(DesignTokens.textMuted)
                }
            }

            plot
                .frame(maxWidth: .infinity)
                .frame(height: 78)   // VARIANT C: trimmed to give the bottom band room

            HStack {
                Text(weeks.first ?? "").font(.abMono(DesignTokens.textXs)).foregroundStyle(DesignTokens.textGhost)
                Spacer()
                HStack(spacing: DesignTokens.space1) {
                    Text(total, format: .number)
                        .font(.abMono(DesignTokens.textXs, weight: .semibold))
                        .foregroundStyle(DesignTokens.textSecondary)
                    Text(totalLabel).font(.adventor(DesignTokens.textXs)).foregroundStyle(DesignTokens.textMuted)
                }
                Spacer()
                Text(weeks.last ?? "").font(.abMono(DesignTokens.textXs)).foregroundStyle(DesignTokens.textGhost)
            }
        }
        .padding(DesignTokens.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(.surface, radius: DesignTokens.radiusLg,
                   lifted: hovering, accentBorder: hovering ? accentBorder : nil)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let n = values.count
        let maxV = CGFloat(peak) * 1.12
        return (0..<n).map { i in
            let x = n <= 1 ? 0 : size.width * CGFloat(i) / CGFloat(n - 1)
            let y = size.height - (CGFloat(values[i]) / maxV) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = points(in: geo.size)

            ZStack {
                // gridlines (ambient — recede, bible §5)
                Path { p in
                    for f in stride(from: 0.0, through: 1.0, by: 0.25) {
                        let y = h * CGFloat(f)
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }.stroke(DesignTokens.chartGrid, lineWidth: 1)

                // area fill (accent -> transparent, top-lit)
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: h))
                    p.addLine(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                    if let last = pts.last { p.addLine(to: CGPoint(x: last.x, y: h)) }
                    p.closeSubpath()
                }.fill(LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.02)],
                                      startPoint: .top, endPoint: .bottom))

                // the line — the one expressive stroke (bible §4/§6)
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(LinearGradient(colors: [accent, accentStrong], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // VARIANT C: flat neon stroke — no bloom (glow is hero-numeral only).

                // end marker
                if let last = pts.last {
                    Circle().fill(accentStrong)
                        .frame(width: 8, height: 8)
                        .position(last)
                    Circle().strokeBorder(DesignTokens.bgSurface, lineWidth: 2)
                        .frame(width: 8, height: 8)
                        .position(last)
                }
            }
        }
    }
}

struct ABTrendRow: View {
    let data: ABLeadsData
    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.space5) {
            ABTrendChart(title: "Leads added / week",
                         weeks: data.leadsAddedWeekly.weeks, values: data.leadsAddedWeekly.values,
                         role: .teal)
                .frame(maxWidth: .infinity)
            ABTrendChart(title: "Leads messaged / week",
                         weeks: data.leadsMessagedWeekly.weeks, values: data.leadsMessagedWeekly.values,
                         role: .pink,
                         // Distinct leads over the window — summing the weekly
                         // buckets would count a lead once per week it was touched.
                         distinctTotal: data.leadsMessagedTotal,
                         totalLabel: "leads reached")
                .frame(maxWidth: .infinity)
        }
    }
}
