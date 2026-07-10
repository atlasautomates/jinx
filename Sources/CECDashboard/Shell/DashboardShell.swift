import SwiftUI

struct DashboardShell: View {
    let dashboard: Dashboard
    var title: String = "CEC Dashboard"
    var isRefreshing: Bool = false
    /// Non-nil when the displayed data is stale (last refresh failed); carries the reason.
    var staleMessage: String? = nil
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let pad = Space.s5
            let gridWidth = max(geo.size.width - pad * 2, 1)
            let bp = dashboard.layout.breakpointName(forWidth: Double(gridWidth))

            VStack(spacing: 0) {
                Toolbar(title: title, breakpoint: bp, isRefreshing: isRefreshing,
                        onRefresh: onRefresh)
                    .padding(.horizontal, pad)
                    .padding(.vertical, Space.s4)

                if let staleMessage {
                    StaleBanner(message: staleMessage)
                        .padding(.horizontal, pad)
                        .padding(.bottom, Space.s3)
                }

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

/// Inline warning shown above the grid when data couldn't be refreshed.
private struct StaleBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StatusStyle.orange.fg)
            Text("Showing last loaded data — couldn't refresh: \(message)")
                .font(.ui(12))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(StatusStyle.orange.bg))
    }
}

private struct Toolbar: View {
    let title: String
    let breakpoint: String
    let isRefreshing: Bool
    let onRefresh: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
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

                ToolbarButton(label: isRefreshing ? "Refreshing…" : "Refresh",
                              enabled: !isRefreshing && onRefresh != nil) {
                    onRefresh?()
                }
            }
        }
    }
}

private struct ToolbarButton: View {
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.ui(12, weight: .medium))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Palette.borderDefault, lineWidth: 1))
        .foregroundStyle(enabled ? Palette.textSecondary : Palette.textMuted)
        .disabled(!enabled)
    }
}
