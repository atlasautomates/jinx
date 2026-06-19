import SwiftUI

struct DashboardShell: View {
    let dashboard: Dashboard

    var body: some View {
        GeometryReader { geo in
            let pad = Space.s5
            let gridWidth = max(geo.size.width - pad * 2, 1)
            let bp = dashboard.layout.breakpointName(forWidth: Double(gridWidth))

            VStack(spacing: 0) {
                Toolbar(breakpoint: bp)
                    .padding(.horizontal, pad)
                    .padding(.vertical, Space.s4)

                ScrollView {
                    WidgetGrid(
                        layout: dashboard.layout,
                        widgets: dashboard.widgets,
                        width: gridWidth
                    )
                    .padding(.horizontal, pad)
                    .padding(.bottom, pad)
                }
            }
        }
        .background(Palette.bgRoot)
    }
}

private struct Toolbar: View {
    let breakpoint: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Lead Dashboard")
                .font(.display(22, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Spacer()

            HStack(spacing: Space.s2) {
                Text(breakpoint.uppercased())
                    .font(.dataMono(11, weight: .medium))
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.accentBg))
                    .overlay(Capsule().stroke(Palette.accentBorder, lineWidth: 1))
                    .foregroundStyle(Palette.accent)

                Button(action: {}) {
                    Text("Re-layout")
                        .font(.ui(12, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.bgElevated))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Palette.borderDefault, lineWidth: 1))
                .foregroundStyle(Palette.textMuted)
                .disabled(true)   // wired up in M2
                .help("Adaptive re-layout arrives in M2 (claude -p)")
            }
        }
    }
}
