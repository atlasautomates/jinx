import SwiftUI

struct RootView: View {
    @State private var model = DashboardViewModel()
    @State private var campaignModel = CampaignDashboardViewModel()
    @State private var pipelineModel = PipelineDashboardViewModel()
    @State private var inspectorModel = LeadInspectorModel()
    // @State is load-bearing: it persists ONE TitlebarHover across body re-evals, so its
    // `installed` guard stays true and only one hover view is ever injected. Don't demote.
    @State private var titlebarHover = TitlebarHover()

    var body: some View {
        TabView {
            leadsTab
                .tabItem { Label("Leads", systemImage: "person.3.fill") }
            campaignsTab
                .tabItem { Label("Campaigns", systemImage: "paperplane.fill") }
            pipelineTab
                .tabItem { Label("Pipeline", systemImage: "arrow.triangle.branch") }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 600)
        .background(WindowAccessor { titlebarHover.attach(to: $0) })
        .task { await model.load() }            // initial Leads load
        .task { await campaignModel.load() }    // initial Campaigns load
        .task { await pipelinePolling() }       // Pipeline: own loop (fast while a run is live)
        .task { await periodicRefresh() }       // re-fetch Leads+Campaigns every 10 min
    }

    /// Re-fetch Leads + Campaigns every 10 minutes while the app is open. Leads' layout
    /// passes through the if-changed gate (Haiku only on profile shift); Campaigns uses a
    /// fixed deterministic layout, so it just re-fetches data. Manual Refresh stays per-tab.
    /// (Pipeline is deliberately NOT in this fan-out — `pipelinePolling` owns its cadence.)
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

    /// Pipeline poll loop (P5-3): 8s while a run is live so stages visibly advance
    /// (the acceptance is literally watching an opener appear after personalize),
    /// 10 min when idle. Structured `.task` — cancelled with the window, so the
    /// fast cadence can never outlive the UI it exists for.
    private func pipelinePolling() async {
        await pipelineModel.load()   // initial load
        while !Task.isCancelled {
            let interval: UInt64 = pipelineModel.hasRunningRun ? 8 : 600
            try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            if Task.isCancelled { break }
            await pipelineModel.load()
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

    // MARK: - Pipeline tab (fixed deterministic layout + lead inspector; READ-ONLY)

    // NOTE (platform review): WindowGroup allows Cmd-N; each extra window runs
    // its own poll loops. Accepted — read-only anon GETs, and the loops die
    // with their window. Revisit as a `Window` scene if it ever matters.
    @ViewBuilder
    private var pipelineTab: some View {
        VSplitView {
            pipelineDashboard
                .frame(minHeight: 240)   // 240+160 fits the 600pt window floor
            LeadInspectorView(model: inspectorModel)
                .frame(minHeight: 160)   // with tab bar + splitter headroom
        }
    }

    @ViewBuilder
    private var pipelineDashboard: some View {
        switch pipelineModel.state {
        case .idle, .loading:
            LoadingView()
        case .loaded(let dashboard):
            DashboardShell(
                dashboard: dashboard, title: "Pipeline", isRefreshing: pipelineModel.isRefreshing,
                onRefresh: { Task { await pipelineModel.load() } }
            )
        case .stale(let dashboard, _, let message):
            DashboardShell(
                dashboard: dashboard, title: "Pipeline", isRefreshing: pipelineModel.isRefreshing,
                staleMessage: message,
                onRefresh: { Task { await pipelineModel.load() } }
            )
        case .failed(let message):
            ErrorView(message: message, onRetry: { Task { await pipelineModel.load() } })
        }
    }
}
