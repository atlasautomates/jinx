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
        VStack(alignment: .leading, spacing: DesignTokens.space5) {
            header
            ABKpiHeroRow(data: data, forcedPressedHero: interactionDemo)      // level 1
            ABTrendRow(data: data)                                            // level 2
            ABBreakdownRowGroup(data: data,
                forcedHoverStatusLabel: interactionDemo ? "Replied" : nil)    // level 3
            ABRecentLeadsTable(leads: data.recentLeads,
                forcedHoverIndex: interactionDemo ? 1 : nil,
                staticRender: staticRender)                                   // level 4
                .frame(maxHeight: staticRender ? 320 : .infinity, alignment: .top)
                .clipped()
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
                    .frame(width: 34, height: 2)
                    .shadow(color: DesignTokens.accent.opacity(0.7), radius: 4)
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
