import SwiftUI

struct RootView: View {
    @State private var model = DashboardViewModel()
    @State private var campaignModel = CampaignDashboardViewModel()
    // @State is load-bearing: it persists ONE TitlebarHover across body re-evals, so its
    // `installed` guard stays true and only one hover view is ever injected. Don't demote.
    @State private var titlebarHover = TitlebarHover()

    var body: some View {
        TabView {
            leadsTab
                .tabItem { Label("Leads", systemImage: "person.3.fill") }
            campaignsTab
                .tabItem { Label("Campaigns", systemImage: "paperplane.fill") }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 600)
        .background(WindowAccessor { titlebarHover.attach(to: $0) })
        .task { await model.load() }            // initial Leads load
        .task { await campaignModel.load() }    // initial Campaigns load
        .task { await periodicRefresh() }       // re-fetch both every 10 min
    }

    /// Re-fetch both tabs every 10 minutes while the app is open. Leads' layout passes
    /// through the if-changed gate (Haiku only on profile shift); Campaigns uses a fixed
    /// deterministic layout, so it just re-fetches data. Manual Refresh stays per-tab.
    private func periodicRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)   // 10 minutes
            if Task.isCancelled { break }
            // Refresh both tabs concurrently — they hit independent tables and each
            // guards its own in-flight refresh, so there's no ordering dependency.
            async let leads: Void = model.load()
            async let campaigns: Void = campaignModel.load()
            _ = await (leads, campaigns)
        }
    }

    // MARK: - Leads tab (adaptive layout via Haiku; Re-layout button enabled)

    @ViewBuilder
    private var leadsTab: some View {
        switch model.state {
        case .idle, .loading:
            LoadingView()
        case .loaded(let dashboard):
            DashboardShell(
                dashboard: dashboard, title: "Leads", isRefreshing: model.isRefreshing,
                onRefresh: { Task { await model.load() } },
                onRelayout: { Task { await model.load(force: true) } }
            )
        case .stale(let dashboard, _, let message):
            DashboardShell(
                dashboard: dashboard, title: "Leads", isRefreshing: model.isRefreshing,
                staleMessage: message,
                onRefresh: { Task { await model.load() } },
                onRelayout: { Task { await model.load(force: true) } }
            )
        case .failed(let message):
            ErrorView(message: message, onRetry: { Task { await model.load() } })
        }
    }

    // MARK: - Campaigns tab (fixed deterministic layout; no Re-layout button)

    @ViewBuilder
    private var campaignsTab: some View {
        switch campaignModel.state {
        case .idle, .loading:
            LoadingView()
        case .loaded(let dashboard):
            DashboardShell(
                dashboard: dashboard, title: "Campaigns", isRefreshing: campaignModel.isRefreshing,
                onRefresh: { Task { await campaignModel.load() } }
            )
        case .stale(let dashboard, _, let message):
            DashboardShell(
                dashboard: dashboard, title: "Campaigns", isRefreshing: campaignModel.isRefreshing,
                staleMessage: message,
                onRefresh: { Task { await campaignModel.load() } }
            )
        case .failed(let message):
            ErrorView(message: message, onRetry: { Task { await campaignModel.load() } })
        }
    }
}
