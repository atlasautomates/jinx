import SwiftUI

/// Card surface — the standard panel chrome for every widget.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(Palette.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .stroke(Palette.borderDefault, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4)
    }
}

/// Small uppercase muted label used as a widget header.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.ui(11, weight: .medium))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textMuted)
    }
}

/// Pill badge for statuses (sentiment, stage, campaign state).
struct Badge: View {
    let text: String
    let style: StatusStyle

    var body: some View {
        Text(text)
            .font(.ui(11, weight: .medium))
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(style.bg))
            .foregroundStyle(style.fg)
            .lineLimit(1)
    }
}

/// Minimal dependency-free sparkline for KPI cards.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = values.max() ?? 1
            let minV = values.min() ?? 0
            let range = max(maxV - minV, 0.0001)
            Path { path in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat((v - minV) / range))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
