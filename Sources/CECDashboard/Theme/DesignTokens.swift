import SwiftUI

// MARK: - Color helpers

extension Color {
    /// Parse a 6-digit "#rrggbb" hex into an sRGB color. Only 6-digit rrggbb is
    /// supported; malformed input yields a visible grey fallback (not silent black),
    /// so a bad token surfaces rather than disappearing — matters once tokens become
    /// data-driven.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else {
            self = Color(.sRGB, red: 0.40, green: 0.40, blue: 0.45, opacity: 1)
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// rgba() convenience matching the design-system token values.
func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

// MARK: - Palette (from .claude/design/design-systems/atlasautomates, dark mode)

enum Palette {
    static let bgRoot = Color(hex: "050508")
    static let bgSurface = Color(hex: "0a0a10")
    static let bgElevated = Color(hex: "101010")

    static let textPrimary = Color(hex: "f0f0f5")
    static let textSecondary = Color(hex: "c0c0d8")
    static let textMuted = Color(hex: "6a6a88")
    static let textGhost = Color(hex: "333348")

    static let borderSubtle = Color(hex: "111118")
    static let borderDefault = Color(hex: "1a1a2a")
    static let borderHover = Color(hex: "2a2a4a")

    static let accent = Color(hex: "dd7bbb")
    static let accentGold = Color(hex: "d79f1e")
    static let accentBg = Color(hex: "dd7bbb").opacity(0.06)
    static let accentBorder = Color(hex: "dd7bbb").opacity(0.27)
}

// MARK: - Status badge styles (paired bg + fg per state)

enum StatusStyle: String {
    case green, purple, blue, orange, red, neutral

    init(token: String?) {
        self = token.flatMap { StatusStyle(rawValue: $0.lowercased()) } ?? .neutral
    }

    var bg: Color {
        switch self {
        case .green: return rgba(34, 255, 153, 0.118)
        case .purple: return rgba(131, 84, 254, 0.21)
        case .blue: return rgba(0, 119, 255, 0.227)
        case .orange: return rgba(250, 130, 0, 0.133)
        case .red: return rgba(255, 23, 63, 0.176)
        case .neutral: return Palette.textMuted.opacity(0.14)
        }
    }

    var fg: Color {
        switch self {
        case .green: return rgba(70, 254, 165, 0.83)
        case .purple: return Color(hex: "BAA7FF")
        case .blue: return Color(hex: "70B8FF")
        case .orange: return Color(hex: "FFCA16")
        case .red: return Color(hex: "FF9592")
        case .neutral: return Palette.textSecondary
        }
    }
}

/// Map a free-text categorical value (sentiment, stage, …) to a badge style.
func statusForLabel(_ raw: String) -> StatusStyle {
    switch raw.lowercased() {
    case "positive", "won", "enriched", "active": return .green
    case "neutral", "proposal", "discovery", "running": return .blue
    case "negative", "lost", "bounced", "failed": return .red
    case "pending", "negotiation", "on hold", "paused": return .orange
    default: return .purple
    }
}

// MARK: - Spacing (8px grid)

enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s8: CGFloat = 40
    static let s10: CGFloat = 64
}

// MARK: - Radius

enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let pill: CGFloat = 9999
}

// MARK: - Typography

extension Font {
    /// SF Mono — data values, tables, numbers.
    static func dataMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// System sans — UI chrome, labels, body.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Display serif — headings (system serif fallback for Playfair in v0).
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}
