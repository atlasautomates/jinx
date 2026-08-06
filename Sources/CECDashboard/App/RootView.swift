import SwiftUI

struct RootView: View {
    @State private var model = DashboardViewModel()
    @State private var searchModel = LeadSearchModel()
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
        .task { await initialLeadsLoad() }       // initial Leads load
        // Offline dev mode drives the Leads tab only: every other loop below would
        // reach for the Keychain and the network, which is the whole point of not
        // running them.
        .task { if !LeadsFixtureSource.isRequested { await campaignModel.load() } }
        .task { if !LeadsFixtureSource.isRequested { await backlogModel.load() } }
        .task { if !LeadsFixtureSource.isRequested { await pipelinePolling() } }
        .task { if !LeadsFixtureSource.isRequested { await periodicRefresh() } }
        .task { await refreshOnWake() }
    }

    /// Normal launch → live fetch. `--fixture` (DEBUG-only) → synthetic book, no
    /// Keychain and no network, so the REAL window can be driven offline while
    /// iterating on layout the still harness cannot capture (scroll behaviour).
    private func initialLeadsLoad() async {
        if LeadsFixtureSource.isRequested {
            model.loadFixture()
            searchModel.fixtureRows = model.snapshotLeads
            syncSearchScope()
        } else {
            // Never leave a fixture book behind a live snapshot: search would keep
            // answering from synthetic rows while the tab showed real ones.
            searchModel.fixtureRows = nil
            await model.load()
            syncSearchScope()
        }
    }

    /// Re-fetch when the machine wakes or the app is brought forward.
    ///
    /// `periodicRefresh` is a `Task.sleep` loop, and that clock does not advance
    /// while the Mac is asleep — a lid opened after a weekend resumes mid-interval
    /// and keeps painting pre-sleep numbers. (The "as of HH:mm" stamp in the header
    /// is the belt to this pair of braces.)
    private func refreshOnWake() async {
        guard !LeadsFixtureSource.isRequested else { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in workspace.notifications(named: NSWorkspace.didWakeNotification) {
                    await reloadLeads()
                }
            }
            group.addTask { @MainActor in
                for await _ in center.notifications(named: NSApplication.didBecomeActiveNotification) {
                    await reloadLeads()
                }
            }
        }
    }

    /// Wake/activation refresh, throttled.
    ///
    /// `didBecomeActive` fires on every Cmd-Tab back into the window, and each
    /// refresh is a full book walk (~14 PostgREST round trips today, ~47 at 10x).
    /// The in-flight guard prevents overlap, not repetition — so this adds the
    /// missing floor. The manual Refresh button deliberately bypasses it.
    @MainActor
    private func reloadLeads(minInterval: TimeInterval = 60) async {
        if let loadedAt = model.loadedAt,
           Date().timeIntervalSince(loadedAt) < minInterval { return }
        await model.load()
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
            async let drilled: Void = campaignDrill.refreshLevel()
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
            // Search still works when the SNAPSHOT read fails — it is an independent
            // server query, and "find the lead I know exists" is exactly what you
            // want when the dashboard itself is broken. Previously the box lived
            // inside the loaded arm, so the one working feature disappeared with the
            // failure (and ⌘F went disabled with it).
            leadsFailed(message: message)
        } else {
            ABLoadingView()
        }
    }

    /// Failure state that keeps the search surface alive.
    private func leadsFailed(message: String) -> some View {
        VStack(spacing: 0) {
            ABSearchOnlyHeader(
                query: Bindable(searchModel).query,
                state: searchModel.state,
                onSubmit: { searchModel.submit() },
                onClear: { searchModel.clear() },
                onSelectLead: LeadsFixtureSource.isRequested ? nil : { lead in
                    guard let id = lead.leadID else { return }
                    profilePresenter.active = LeadRef(id: id, companyName: lead.company, email: nil)
                })
            ABErrorView(message: message, onRetry: { retryLeads() })
        }
    }

    /// The live ABLeads surface: row tap → shared profile sheet, header refresh →
    /// live re-fetch, stale banner when a refresh degraded, filter bar → local
    /// re-derivation, search box → server query over the whole book.
    private func liveLeads(_ data: ABLeadsData, staleMessage: String?) -> some View {
        let fixture = LeadsFixtureSource.isRequested
        return ABLeadsView(
            data: data,
            // Fixture rows are inert. The profile sheet builds its OWN live client
            // (LeadProfileModel.load → SupabaseClient.make), so a synthetic row could
            // raise a Keychain prompt and then render a real lead's dossier beside
            // invented ones — in the mode whose whole claim is "no Keychain, no
            // network". Every other fixture guard lives in this file; this seam was
            // the one that had none.
            onSelectLead: fixture ? nil : { lead in
                guard let id = lead.leadID else { return }
                profilePresenter.active = LeadRef(id: id, companyName: lead.company, email: nil)
            },
            // In fixture mode a refresh would perform the REAL Keychain + network
            // load, replacing (or, on failure, re-labelling) synthetic rows as live
            // ones. The view treats nil as "no refresh control".
            onRefresh: fixture ? nil : { Task { await model.load() } },
            isRefreshing: model.isRefreshing,
            staleMessage: staleMessage,
            fixtureNotice: fixture ? LeadsFixtureSource.banner : nil,
            loadedAt: fixture ? nil : model.loadedAt,
            requestedFilter: model.filter,
            onFilterChange: { newFilter in
                model.apply(newFilter)
                syncSearchScope()
            },
            searchQuery: Bindable(searchModel).query,
            searchState: searchModel.state,
            onSearchSubmit: {
                // Scope first: a search submitted before the scope is pushed would
                // render its hits unfiltered for one pass.
                syncSearchScope()
                searchModel.submit()
            },
            onSearchClear: { searchModel.clear() },
            searchIgnoringFilters: searchModel.ignoringFilters,
            onToggleSearchFilters: { searchModel.setIgnoringFilters($0) }
        )
    }

    /// Push the tab's APPLIED filter into the search model, so hits are narrowed by
    /// the same lens as everything else on screen (and anything it removes is counted
    /// and offered rather than silently dropped).
    private func syncSearchScope() {
        searchModel.updateScope(filter: model.state.value?.effectiveFilter ?? .all,
                                facets: model.facetResolver)
    }

    /// Retry from the error state — offline mode retries the fixture, not the network.
    private func retryLeads() {
        if LeadsFixtureSource.isRequested {
            model.loadFixture()
            searchModel.fixtureRows = model.snapshotLeads
            syncSearchScope()
        } else {
            Task { await model.load() }
        }
    }

    // MARK: - Campaigns tab (drill-down: campaigns → leads → correspondence)

    @ViewBuilder
    private var campaignsTab: some View {
        if LeadsFixtureSource.isRequested {
            // Never loaded offline; an indefinite spinner would be
            // indistinguishable from a hung fetch.
            ABErrorView(message: "Offline fixture mode — this tab needs live credentials.",
                        onRetry: nil)
        } else {
            campaignsLive
        }
    }

    @ViewBuilder
    private var campaignsLive: some View {
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
        if LeadsFixtureSource.isRequested {
            ABErrorView(message: "Offline fixture mode — this tab needs live credentials.",
                        onRetry: nil)
        } else {
            pipelineLive
        }
    }

    @ViewBuilder
    private var pipelineLive: some View {
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
