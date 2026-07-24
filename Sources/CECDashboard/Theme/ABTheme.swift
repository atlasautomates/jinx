import SwiftUI

// Small DERIVED helpers over the generated `ABTokens.swift` (DesignTokens).
// No color/size literals live here — every value traces to a token. These are
// the ARM-B (neon-teal Leads re-skin) building blocks: fonts, motion, and the
// tokenized elevated-surface treatment (one overhead light source, bible §5).

// MARK: - Typography (2 faces max: TeX Gyre Adventor + SF Mono)

extension Font {
    /// TeX Gyre Adventor — display + UI. Only Regular + Bold cuts are installed,
    /// so weight contrast is Regular vs Bold (decision-log #7). PostScript names
    /// come from the `--font-*` tokens.
    static func adventor(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? DesignTokens.fontDisplay : DesignTokens.fontSans, size: size)
    }

    /// SF Mono — tabular figures only (counts, dates). The `--font-mono` token
    /// names it; system monospaced resolves the same face with reliable weights.
    static func abMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Motion tokens -> SwiftUI curves

enum ABMotion {
    /// `--ease-smooth` = cubic-bezier(0.4, 0, 0.2, 1).
    static func smooth(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }
    static var fast: Animation { smooth(DesignTokens.durationFast) }
    static var normal: Animation { smooth(DesignTokens.durationNormal) }
    static var medium: Animation { smooth(DesignTokens.durationMedium) }
}

// MARK: - Elevated surface (one overhead light source, bible §5)

/// A raised panel: fill is a subtle top->bottom lightness gradient (lighter top
/// edge = light from above), stroke is a top-lit 1px border. No inline shadows —
/// depth is surface-lightness steps + borders (bible §5). `lifted` bumps the
/// whole panel one lightness step for hover feedback (bible §6).
struct ABSurface: ViewModifier {
    enum Level { case surface, elevated }
    var level: Level
    var radius: CGFloat = DesignTokens.radiusLg
    var lifted: Bool = false
    /// Optional accent border tint (teal or pink) to color-code a panel's role.
    var accentBorder: Color? = nil

    private var fillTop: Color {
        switch (level, lifted) {
        case (.surface, false):  return DesignTokens.bgElevated
        case (.surface, true):   return DesignTokens.bgHighlight
        case (.elevated, false): return DesignTokens.bgHighlight
        case (.elevated, true):  return DesignTokens.bgHighlight
        }
    }
    private var fillBottom: Color {
        switch (level, lifted) {
        case (.surface, false):  return DesignTokens.bgSurface
        case (.surface, true):   return DesignTokens.bgElevated
        case (.elevated, false): return DesignTokens.bgElevated
        case (.elevated, true):  return DesignTokens.bgHighlight
        }
    }
    private var strokeTop: Color {
        if let a = accentBorder { return a }
        return lifted ? DesignTokens.borderHover : DesignTokens.borderDefault
    }
    private var strokeBottom: Color { DesignTokens.borderSubtle }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [fillTop, fillBottom],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [strokeTop, strokeBottom],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func abSurface(_ level: ABSurface.Level,
                   radius: CGFloat = DesignTokens.radiusLg,
                   lifted: Bool = false,
                   accentBorder: Color? = nil) -> some View {
        modifier(ABSurface(level: level, radius: radius, lifted: lifted, accentBorder: accentBorder))
    }
}

// MARK: - Section label (ambient, level-3 chrome)

struct ABSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.adventor(DesignTokens.textXs, bold: true))
            .tracking(1.4)
            .foregroundStyle(DesignTokens.textMuted)
    }
    init(_ text: String) { self.text = text }
}
