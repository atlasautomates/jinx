import SwiftUI

struct RootView: View {
    private let dashboard = MockData.dashboard

    var body: some View {
        Group {
            if let dashboard {
                DashboardShell(dashboard: dashboard)
            } else {
                // Fail-closed placeholder (M0 controls the JSON, so this should
                // never appear; in M2 a decode failure falls back to a default layout).
                VStack(spacing: Space.s3) {
                    Text("Couldn't load the dashboard layout.")
                        .font(.ui(14, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Mock layout/widget JSON failed to decode.")
                        .font(.ui(12))
                        .foregroundStyle(Palette.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.bgRoot)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 600)
    }
}
