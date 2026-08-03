import SwiftUI

struct RootView: View {
    @State private var model = DashboardViewModel()
    @State private var searchModel = LeadSearchModel()
    @State private var campaignModel = CampaignDashboardViewModel()
    @State private var pipelineModel = PipelineDashboardViewModel()
    @State private var inspectorModel = LeadInspectorModel()
    @State private var campaignInspectorModel = CampaignInspectorModel()
    @State private var backlogModel = BacklogViewModel()
    // One profile seam for every tab: rows set `presenter.active`, this view
    // presents the sheet (P3).
    @State private var profilePresenter = ProfilePresenter()
    // Pinned leads (P5): local JSON store, loaded once, injected app-wide.
    @State private var pinsModel = PinsModel()
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
        .environment(profilePresenter)
        .environment(pinsModel)
        .sheet(item: Bindable(profilePresenter).active) { ref in
            // Explicit injection: sheet content is a separate presentation
            // host — never rely on cross-boundary environment inheritance
            // (platform review; the pin button consumes both).
            LeadProfileView(ref: ref)
                .environment(profilePresenter)
                .environment(pinsModel)
        }
        .background(WindowAccessor { titlebarHover.attach(to: $0) })
        .task { await initialLeadsLoad() }       // initial Leads load
        // Offline dev mode drives the Leads tab only: every other loop below would
        // reach for the Keychain and the network, which is the whole point of not
        // running them.
        .task { if !LeadsFixtureSource.isRequested { await campaignModel.load() } }
        .task { if !LeadsFixtureSource.isRequested { await backlogModel.load() } }
        .task { if !LeadsFixtureSource.isRequested { await pipelinePolling() } }
        .task { if !LeadsFixtureSource.isRequested { await periodicRefresh() } }
    }

    /// Normal launch → live fetch. `--fixture` (dev-only) → synthetic book, no
    /// Keychain and no network, so the REAL window can be driven offline while
    /// iterating on layout the still harness cannot capture (scroll behaviour).
    private func initialLeadsLoad() async {
        if LeadsFixtureSource.isRequested {
            model.loadFixture()
            searchModel.fixtureRows = model.snapshotLeads
        } else {
            await model.load()
        }
    }

    /// Re-fetch Leads + Campaigns + backlog every 10 minutes while the app is open.
    /// Each tab's layout is deterministic, so only the data changes — the live Leads
    /// tab re-maps `model`'s fetch into `ABLeadsData` on each pass. Manual Refresh
    /// stays per-tab. (Pipeline is deliberately NOT in this fan-out —
    /// `pipelinePolling` owns its faster cadence.)
    private func periodicRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)   // 10 minutes
            if Task.isCancelled { break }
            // Refresh concurrently — independent tables, each guards its own
            // in-flight refresh, so there's no ordering dependency.
            async let leads: Void = model.load()
            async let campaigns: Void = campaignModel.load()
            async let backlog: Void = backlogModel.load()
            _ = await (leads, campaigns, backlog)
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

    // MARK: - Leads tab (re-skinned ABLeads, live data)

    // The Leads tab renders `ABLeadsView` from the LIVE pipeline: DashboardViewModel
    // fetches Supabase (LeadsRepository → DashboardInputs) and maps it into
    // `ABLeadsData`. The pinned strip rides on top; rows/pins open the shared lead
    // profile. Loadable states render distinctly (loading / error / stale) — never a
    // blank black screen. The `--screenshot` harness renders the FROZEN fixture
    // through this same view code (no network). (decision-log #16)
    @ViewBuilder
    private var leadsTab: some View {
        VStack(spacing: 0) {
            PinnedStrip()
            leadsContent
        }
        .background(DesignTokens.bgRoot)
    }

    @ViewBuilder
    private var leadsContent: some View {
        // loaded and stale share ONE structural arm so SwiftUI keeps the
        // ABLeads subtree's identity across stale⇄loaded flips — a transient
        // refresh failure must not reset scroll/hover state (S05 review fix).
        if let data = model.state.value {
            liveLeads(data, staleMessage: model.state.staleMessage)
        } else if case .failed(let message) = model.state {
            ABErrorView(message: message, onRetry: { Task { await model.load() } })
        } else {
            ABLoadingView()
        }
    }

    /// The live ABLeads surface: row tap → shared profile sheet, header refresh →
    /// live re-fetch, stale banner when a refresh degraded, filter bar → local
    /// re-derivation, search box → server query over the whole book.
    private func liveLeads(_ data: ABLeadsData, staleMessage: String?) -> some View {
        ABLeadsView(
            data: data,
            onSelectLead: { lead in
                guard let id = lead.leadID else { return }
                profilePresenter.active = LeadRef(id: id, companyName: lead.company, email: nil)
            },
            onRefresh: { Task { await model.load() } },
            isRefreshing: model.isRefreshing,
            staleMessage: staleMessage,
            onFilterChange: { model.apply($0) },
            searchQuery: Bindable(searchModel).query,
            searchState: searchModel.state,
            onSearchSubmit: { searchModel.submit() },
            onSearchClear: { searchModel.clear() }
        )
    }

    // MARK: - Campaigns tab (fixed deterministic layout; no Re-layout button)

    @ViewBuilder
    private var campaignsTab: some View {
        switch campaignModel.state {
        case .idle, .loading:
            LoadingView()
        case .loaded(let dashboard):
            campaignsSplit(dashboard: dashboard, staleMessage: nil)
        case .stale(let dashboard, _, let message):
            campaignsSplit(dashboard: dashboard, staleMessage: message)
        case .failed(let message):
            ErrorView(message: message, onRetry: { Task { await campaignModel.load() } })
        }
    }

    /// Aggregate dashboard on top, campaign inspector below (P4) — the same
    /// VSplitView shape as the Pipeline tab.
    private func campaignsSplit(dashboard: Dashboard, staleMessage: String?) -> some View {
        VSplitView {
            DashboardShell(
                dashboard: dashboard, title: "Campaigns", isRefreshing: campaignModel.isRefreshing,
                staleMessage: staleMessage,
                onRefresh: { Task { await campaignModel.load() } }
            )
            .frame(minHeight: 240)
            CampaignInspectorView(model: campaignInspectorModel,
                                  summaries: campaignModel.summaries)
                .frame(minHeight: 180, idealHeight: 300)
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
                .frame(minHeight: 220)
            BacklogBoardView(model: backlogModel)
                .frame(minHeight: 96, idealHeight: 150)   // P6 backlog board
            LeadInspectorView(model: inspectorModel)
                .frame(minHeight: 150)
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
