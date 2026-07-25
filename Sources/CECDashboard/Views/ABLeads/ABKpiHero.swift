import SwiftUI

// LEVEL 1 (bible §1 primary focus): the two conversion ratios. The hero
// (emailed-of-scraped) wins the 2-second test — biggest type, teal, most
// elevated. The companion (replies) is pink = the reward role (decision-log #13).

struct ABKpiCard: View {
    enum Role { case hero, reward }

    let role: Role
    let percent: Double        // e.g. 69.4
    let caption: String        // "Emailed of scraped"
    let numerator: Int
    let denominator: Int
    let numeratorLabel: String // "emailed"
    let denominatorLabel: String // "scraped"
    /// Force the pressed (sunk) state for the interaction-demo preview.
    var forcedPressed: Bool = false

    @State private var hovering = false

    private var accent: Color { role == .hero ? DesignTokens.accent : DesignTokens.accentPink }
    private var accentStrong: Color { role == .hero ? DesignTokens.accentStrong : DesignTokens.accentPinkStrong }
    private var accentBorder: Color { role == .hero ? DesignTokens.accentBorder : DesignTokens.accentPinkBorder }
    private var pressed: Bool { forcedPressed }
    /// VARIANT C: glow/bloom is confined to the single hero numeral (the one
    /// special moment). The reward KPI keeps its pink hue but stays FLAT — on
    /// true black, flat neon still pops.
    private var isHero: Bool { role == .hero }

    private var heroNumberSize: CGFloat { role == .hero ? DesignTokens.text4xl : DesignTokens.text3xl }
    /// VARIANT C demotion: hero sits at the highest elevation (closest = top
    /// priority, bible §5); the reward companion drops one surface step back.
    private var surfaceLevel: ABSurface.Level { role == .hero ? .elevated : .surface }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(spacing: DesignTokens.space2) {
                Circle().fill(accent).frame(width: 7, height: 7)
                ABSectionLabel(caption)
            }

            // The one display-type moment (bible §4): the ratio, huge, Adventor Bold.
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space1) {
                Text(percent, format: .number.precision(.fractionLength(1)))
                    .font(.adventor(heroNumberSize, bold: true))
                    .foregroundStyle(accent)
                    // The ONLY glow in the view — the hero numeral blooms; it
                    // intensifies on hover. The reward numeral stays flat.
                    .shadow(color: isHero ? accent.opacity(hovering ? 0.60 : 0.40) : .clear,
                            radius: isHero ? (hovering ? 18 : 11) : 0)
                Text("%")
                    .font(.adventor(role == .hero ? DesignTokens.text2xl : DesignTokens.textXl, bold: true))
                    .foregroundStyle(accentStrong)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            // Ratio bar — fills to the percentage (deterministic, data-driven).
            ratioBar

            HStack(spacing: DesignTokens.space1) {
                Text(numerator, format: .number)
                    .font(.abMono(DesignTokens.textBase, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(numeratorLabel).font(.adventor(DesignTokens.textSm)).foregroundStyle(DesignTokens.textMuted)
                Text("/").font(.abMono(DesignTokens.textBase)).foregroundStyle(DesignTokens.textGhost)
                Text(denominator, format: .number)
                    .font(.abMono(DesignTokens.textBase, weight: .semibold))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(denominatorLabel).font(.adventor(DesignTokens.textSm)).foregroundStyle(DesignTokens.textMuted)
            }
        }
        .padding(DesignTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(surfaceLevel, radius: DesignTokens.radiusXl,
                   lifted: hovering && !pressed, accentBorder: accentBorder)
        .scaleEffect(pressed ? 0.985 : (hovering ? 1.006 : 1.0))
        .brightness(pressed ? -0.02 : 0)
        .animation(ABMotion.fast, value: hovering)
        .animation(ABMotion.fast, value: pressed)
        .onHover { hovering = $0 }
    }

    private var ratioBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.bgRoot)
                Capsule()
                    .fill(LinearGradient(colors: [accent, accentStrong],
                                         startPoint: .leading, endPoint: .trailing))
                    // Clamp the fill fraction to [0,1] — a ratio can legitimately
                    // exceed 100% (e.g. reply events vs a small emailed base) and
                    // must never overrun its track.
                    .frame(width: max(6, geo.size.width * CGFloat(min(1.0, max(0.0, percent / 100.0)))))
                    // VARIANT C: flat neon fill — no bloom (glow is hero-numeral only).
            }
        }
        .frame(height: 8)
        .overlay(Capsule().strokeBorder(DesignTokens.borderSubtle, lineWidth: 1))
    }
}

struct ABKpiHeroRow: View {
    let data: ABLeadsData
    var forcedPressedHero: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.space5) {
            ABKpiCard(role: .hero,
                      percent: data.emailedOfScrapedPct,
                      caption: "Emailed of scraped",
                      // Denominator matches the ratio's grain: exact total normally,
                      // or the fetched window in the degraded fallback (F7).
                      numerator: data.totals.emailed,
                      denominator: data.emailedDenominator ?? data.totals.scraped,
                      numeratorLabel: "emailed", denominatorLabel: "scraped",
                      forcedPressed: forcedPressedHero)
                .frame(maxWidth: .infinity)   // hero flexes wide (bible §1 single focus)
            ABKpiCard(role: .reward,
                      percent: data.repliesOfEmailedPct,
                      caption: "Replies of emailed",
                      numerator: data.totals.replies, denominator: data.totals.emailed,
                      numeratorLabel: "replies", denominatorLabel: "emailed")
                .frame(width: 440)            // companion is narrower than the hero
        }
    }
}
