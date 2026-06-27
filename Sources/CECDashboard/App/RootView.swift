import SwiftUI

struct RootView: View {
    @State private var model = DashboardViewModel()
    // @State is load-bearing: it persists ONE TitlebarHover across body re-evals, so its
    // `installed` guard stays true and only one hover view is ever injected. Don't demote.
    @State private var titlebarHover = TitlebarHover()

    var body: some View {
        content
            .preferredColorScheme(.dark)
            .frame(minWidth: 820, minHeight: 600)
            .background(WindowAccessor { titlebarHover.attach(to: $0) })
            .task { await model.load() }       // initial load on appear
            .task { await hourlyRefresh() }    // re-fetch hourly; layout re-gens only if changed
    }

    /// Re-fetch every hour while the app is open. Data refreshes; the layout passes
    /// through the if-changed gate, so Haiku is called only when the profile shifted.
    private func hourlyRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
            if Task.isCancelled { break }
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            LoadingView()

        case .loaded(let dashboard):
            DashboardShell(
                dashboard: dashboard,
                isRefreshing: model.isRefreshing,
                onRefresh: { Task { await model.load() } },
                onRelayout: { Task { await model.load(force: true) } }
            )

        case .stale(let dashboard, _, let message):
            // Keep the data on screen; surface the refresh failure as a banner.
            DashboardShell(
                dashboard: dashboard,
                isRefreshing: model.isRefreshing,
                staleMessage: message,
                onRefresh: { Task { await model.load() } },
                onRelayout: { Task { await model.load(force: true) } }
            )

        case .failed(let message):
            ErrorView(message: message, onRetry: { Task { await model.load() } })
        }
    }
}
