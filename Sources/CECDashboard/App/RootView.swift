import SwiftUI

struct RootView: View {
    @State private var model = DashboardViewModel()
    @State private var campaignModel = CampaignDashboardViewModel()
    @State private var pipelineModel = PipelineDashboardViewModel()
    @State private var inspectorModel = LeadInspectorModel()
    @State private var campaignDrill = CampaignDrillModel()
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
        .task { await model.load() }            // initial Leads load
        .task { await campaignModel.load() }    // initial Campaigns load
        .task { await backlogModel.load() }     // initial backlog scan (P6)
        .task { await pipelinePolling() }       // Pipeline: own loop (fast while a run is live)
        .task { await periodicRefresh() }       // re-fetch Leads+Campaigns+backlog every 10 min
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
            // in-flight refresh, so there's no ordering dependency. The drill
            // refresh is in-place (no clearing), so an open drill's rows stay
            // as fresh as the header above them.
            async let leads: Void = model.load()
            async let campaigns: Void = campaignModel.load()
            async let drilled: Void = campaignDrill.refreshLevel()
            async let backlog: Void = backlogModel.load()
            _ = await (leads, campaigns, drilled, backlog)
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
    /// live re-fetch, stale banner when a refresh degraded.
    private func liveLeads(_ data: ABLeadsData, staleMessage: String?) -> some View {
        ABLeadsView(
            data: data,
            onSelectLead: { lead in
                guard let id = lead.leadID else { return }
                profilePresenter.active = LeadRef(id: id, companyName: lead.company, email: nil)
            },
            onRefresh: { Task { await model.load() } },
            isRefreshing: model.isRefreshing,
            staleMessage: staleMessage
        )
    }

    // MARK: - Campaigns tab (drill-down: campaigns → leads → correspondence)

    @ViewBuilder
    private var campaignsTab: some View {
        // loaded and stale share ONE structural arm (same S05 lesson as the
        // Leads tab): a transient refresh failure must not reset the drill.
        if let inputs = campaignModel.state.value {
            ABCampaignsView(
                inputs: inputs,
                drill: campaignDrill,
                // Refresh reaches the CURRENT drill level too — a header that
                // refreshes over rows that don't is two ages on one screen
                // (state-machine review F2).
                onRefresh: { Task {
                    async let level1: Void = campaignModel.load()
                    async let drilled: Void = campaignDrill.refreshLevel()
                    _ = await (level1, drilled)
                } },
                isRefreshing: campaignModel.isRefreshing,
                staleMessage: campaignModel.state.staleMessage
            )
        } else if case .failed(let message) = campaignModel.state {
            ABErrorView(message: message,
                        onRetry: { Task { await campaignModel.load() } },
                        noun: "campaigns")
        } else {
            ABLoadingView(noun: "campaigns")
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
