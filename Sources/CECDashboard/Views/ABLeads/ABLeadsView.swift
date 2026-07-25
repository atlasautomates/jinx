import SwiftUI

// ARM-B re-skinned Leads tab. Neon-teal view identity + pink reward role, on a
// near-black world. Renders the frozen A/B fixture, no network. Hierarchy top to
// bottom: (1) KPI ratios, (2) trends, (3) breakdowns, (4) recent list.

struct ABLeadsView: View {
    var data: ABLeadsData = .ab
    /// Interaction-demo variant: forces a pressed hero + hovered row/status for
    /// the `leads-detail` preview (states are invisible in a still otherwise).
    var interactionDemo: Bool = false
    /// Offscreen ImageRenderer can't capture ScrollView content — the harness
    /// sets this true to swap ScrollViews for clipped stacks. The running app
    /// leaves it false and stays genuinely scrollable (decision-log #16).
    var staticRender: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            DesignTokens.bgRoot.ignoresSafeArea()

            // One overhead light source for the whole world (bible §5) — a faint
            // teal wash at the top edge, receding downward.
            LinearGradient(colors: [DesignTokens.accent.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)

            content
                .padding(.horizontal, DesignTokens.space6)
                .padding(.vertical, DesignTokens.space5)
        }
        .background(DesignTokens.bgRoot)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var stack: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            header
            ABKpiHeroRow(data: data, forcedPressedHero: interactionDemo)      // level 1
            ABTrendRow(data: data)                                            // level 2

            // VARIANT C: levels 3 + 4 share one band (Arm A layout). The recent
            // list flexes wide on the LEFT so it clears the fold; the three
            // breakdowns stack COMPACTLY in a narrow right column.
            HStack(alignment: .top, spacing: DesignTokens.space5) {
                ABRecentLeadsTable(leads: data.recentLeads,
                    forcedHoverIndex: interactionDemo ? 1 : nil,
                    staticRender: staticRender)                               // level 4
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ABBreakdownRowGroup(data: data,
                    forcedHoverStatusLabel: interactionDemo ? "Replied" : nil) // level 3
                    .frame(width: 384)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        if staticRender {
            stack   // plain layout so ImageRenderer captures it
        } else {
            ScrollView { stack }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignTokens.space1) {
                Text("Leads")
                    .font(.adventor(DesignTokens.textXl, bold: true))
                    .foregroundStyle(DesignTokens.textPrimary)
                Rectangle().fill(DesignTokens.accent)
                    .frame(width: 34, height: 2)   // flat teal rule (glow reserved for hero)
            }
            Spacer()
            HStack(spacing: DesignTokens.space4) {
                summaryStat(value: data.totals.scraped, label: "scraped", color: DesignTokens.textSecondary)
                summaryStat(value: data.totals.emailed, label: "emailed", color: DesignTokens.accent)
                summaryStat(value: data.totals.replies, label: "replies", color: DesignTokens.accentPink)
            }
        }
    }

    private func summaryStat(value: Int, label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space1) {
            Text(value, format: .number)
                .font(.abMono(DesignTokens.textBase, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
        }
    }
}
