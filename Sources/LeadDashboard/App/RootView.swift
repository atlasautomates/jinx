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
            .task { await model.load() }   // initial load on appear
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
                onRefresh: { Task { await model.load() } }
            )

        case .stale(let dashboard, _, let message):
            // Keep the data on screen; surface the refresh failure as a banner.
            DashboardShell(
                dashboard: dashboard,
                isRefreshing: model.isRefreshing,
                staleMessage: message,
                onRefresh: { Task { await model.load() } }
            )

        case .failed(let message):
            ErrorView(message: message, onRetry: { Task { await model.load() } })
        }
    }
}
