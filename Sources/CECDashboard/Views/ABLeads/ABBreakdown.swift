import SwiftUI

// LEVEL 3 (VARIANT C): the stage funnel + three breakdowns — source, region,
// industry — stacked COMPACTLY in a narrow side column (Arm A's density) so
// the same data reads concisely and leaves the recent-leads list room above
// the fold. Horizontal bars, width proportional to the panel max. Partition
// panels use teal; funnel rows color by role (teal/pink/neutral —
// decision-log #5; the warn role retired with the 7.2 stage vocabulary).

struct ABBreakdownPanel: View {
    let title: String
    let items: [ABLeadsData.Breakdown]
    /// Per-row bar color; nil -> teal accent for every row.
    var colorFor: ((String) -> Color)? = nil
    /// Force one row's hover state for the interaction-demo preview.
    var forcedHoverLabel: String? = nil
    /// Honesty note when this breakdown is a windowed slice of a larger total
    /// (e.g. "1000 of 1413") — a faint caption beside the title. nil = exact/
    /// complete (no caption), so the fixture render is unaffected.
    var scopeNote: String? = nil

    // max(1, …) guards the all-zero / empty case: a 0 denominator below would make
    // every bar fraction NaN (0/0). Never divides by zero.
    private var maxCount: Int { max(1, items.map(\.count).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            HStack(spacing: DesignTokens.space2) {
                ABSectionLabel(title)
                if let scopeNote {
                    Text(scopeNote)
                        .font(.abMono(DesignTokens.textXs))
                        .foregroundStyle(DesignTokens.textGhost)
                }
            }
            VStack(spacing: DesignTokens.space1) {
                ForEach(items) { item in
                    ABBreakdownRow(label: item.label, count: item.count,
                                   share: item.share,
                                   fraction: CGFloat(item.count) / CGFloat(maxCount),
                                   color: colorFor?(item.label) ?? DesignTokens.accent,
                                   forcedHover: forcedHoverLabel == item.label)
                }
            }
        }
        .padding(DesignTokens.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(.surface, radius: DesignTokens.radiusLg)
    }
}

private struct ABBreakdownRow: View {
    let label: String
    let count: Int
    /// Retention share (percent of the funnel denominator). Non-nil ONLY for
    /// stage-funnel rows — the cue that these buckets overlap rather than sum.
    var share: Double? = nil
    let fraction: CGFloat
    let color: Color
    var forcedHover: Bool = false

    @State private var hovering = false
    private var active: Bool { hovering || forcedHover }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.adventor(DesignTokens.textXs, bold: active))
                    .foregroundStyle(active ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let share {
                    Text("\(Int(share.rounded()))% ·")
                        .font(.abMono(DesignTokens.textXs))
                        .foregroundStyle(DesignTokens.textGhost)
                }
                Text(count, format: .number)
                    .font(.abMono(DesignTokens.textXs, weight: .semibold))
                    .foregroundStyle(active ? color : DesignTokens.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignTokens.bgRoot)
                    Capsule()
                        // VARIANT C: flat neon bar — no bloom (glow is hero-numeral only);
                        // hover just brightens the fill to full strength.
                        .fill(LinearGradient(
                            colors: active ? [color, color] : [color.opacity(0.85), color.opacity(0.55)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 1)
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
    /// Offscreen render can't capture ScrollView content — clip instead.
    var staticRender: Bool = false
    var forcedHoverStatusLabel: String? = nil

    private func statusColor(_ label: String) -> Color {
        switch ABStatusRole(label) {
        case .reward:  return DesignTokens.accentPink
        case .active:  return DesignTokens.accent
        case .neutral: return DesignTokens.textMuted
        }
    }

    /// VARIANT C: stacked vertically in the narrow side column (Arm A layout).
    /// Every panel counts the SAME filtered lead set the list and the hero use, so
    /// the scope note (when the snapshot itself is a window) applies to all four.
    @ViewBuilder
    private var panels: some View {
        // Ordered by decision value, not by when they were built: pipeline health
        // first, then where the leads came from, then who they are. The new "By
        // region" panel was originally inserted second, which pushed two panels
        // named in the tab's brief below the fold of a column with no scrollbar.
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            // "Stage funnel", deliberately OUT of the "By …" partition grammar:
            // its buckets overlap (Campaigned ⊆ Personalized-ish ⊆ Scraped), and
            // wearing a partition title next to three true partitions made it
            // read as a broken breakdown (design review, 7.2). The per-row
            // retention share is the second cue.
            ABBreakdownPanel(title: "Stage funnel", items: data.byStatus,
                             colorFor: statusColor,
                             forcedHoverLabel: forcedHoverStatusLabel,
                             scopeNote: data.breakdownScopeNote)
            ABBreakdownPanel(title: "By source", items: data.bySource,
                             scopeNote: data.breakdownScopeNote)
            ABBreakdownPanel(title: "By region", items: data.byRegion,
                             scopeNote: data.breakdownScopeNote)
            ABBreakdownPanel(title: "By industry", items: data.byIndustry,
                             scopeNote: data.breakdownScopeNote)
        }
    }

    var body: some View {
        // Own scroll surface, bounded by the band's height (the page does not
        // scroll) — four panels no longer have to fit a short window.
        if staticRender {
            VStack(alignment: .leading, spacing: 0) {
                panels
                Spacer(minLength: 0)
            }
            .clipped()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    panels
                    // Says the column continues, in the same words the lead list
                    // uses — an unscrollbar'd column that simply ends looks complete.
                    Text("scroll for more")
                        .font(.adventor(DesignTokens.textXs))
                        .foregroundStyle(DesignTokens.textGhost)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, DesignTokens.space1)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
