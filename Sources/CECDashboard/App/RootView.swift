import SwiftUI

// 7.2 remap: the app is the LEADS SURFACE only. The Pipeline tab (unused) and
// the Campaigns tab (write access; may return as its own app) are DEPRECATED
// per Adrian's ruling 2026-08-16 — their views, view models and repositories
// are deleted, not hidden: under the reader credential their table reads have
// no data source, so a hidden tab would be a broken tab waiting to be found.
struct RootView: View {
    @State private var model = DashboardViewModel()
    @State private var searchModel = LeadSearchModel()
    // One profile seam for every entry point (rows, search hits, pins): callers
    // set `presenter.active`, this view presents the sheet (P3).
    @State private var profilePresenter = ProfilePresenter()
    // Pinned leads (P5): local JSON store, loaded once, injected app-wide.
    // In `--fixture` mode the store points at a per-run scratch dir: the real
    // pin file would render REAL leads above the synthetic book, and a chip
    // tap opens the live profile sheet — a Keychain + network path one click
    // away in the mode whose whole claim is "no Keychain, no network"
    // (contention lens; same discipline as LeadProfileFixture's previewPins).
    @State private var pinsModel = LeadsFixtureSource.isRequested
        ? PinsModel(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CECDashboard-fixture-pins-\(UUID().uuidString)",
                                    isDirectory: true))
        : PinsModel()
    // @State is load-bearing: it persists ONE TitlebarHover across body re-evals, so its
    // `installed` guard stays true and only one hover view is ever injected. Don't demote.
    @State private var titlebarHover = TitlebarHover()

    var body: some View {
        leadsSurface
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
            .task { await initialLeadsLoad() }       // initial load
            // Offline dev mode never reaches for the Keychain or the network —
            // which is the whole point of not running the refresh loops.
            .task { if !LeadsFixtureSource.isRequested { await periodicRefresh() } }
            // Two sibling .task children instead of one task group: same
            // concurrency, view-lifetime cancellation for free, and no capture
            // pattern the Swift 6 region-isolation checker refuses to check
            // (swift-semantics review, 7.2).
            .task { await refreshOn(NSWorkspace.shared.notificationCenter,
                                    NSWorkspace.didWakeNotification) }
            .task { await refreshOn(NotificationCenter.default,
                                    NSApplication.didBecomeActiveNotification) }
            // Re-push the search scope whenever a load LANDS — the initial-load
            // call site can be deduped by a concurrent wake/activation refresh
            // (load() returns void either way), and a scope pushed against an
            // empty snapshot would leave the facet resolver nil until the next
            // filter change.
            .onChange(of: model.loadedAt) { syncSearchScope() }
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
    private func refreshOn(_ center: NotificationCenter, _ name: Notification.Name) async {
        guard !LeadsFixtureSource.isRequested else { return }
        for await _ in center.notifications(named: name) {
            await reloadLeads()
        }
    }

    /// Wake/activation refresh, throttled.
    ///
    /// `didBecomeActive` fires on every Cmd-Tab back into the window, and each
    /// refresh is a full book walk (multiple PostgREST round trips). The in-flight
    /// guard prevents overlap, not repetition — so this adds the missing floor.
    /// The manual Refresh button deliberately bypasses it.
    @MainActor
    private func reloadLeads(minInterval: TimeInterval = 60) async {
        // Floor on the last ATTEMPT, not the last success: with success-only
        // stamping the floor was vacuous precisely while loads were failing,
        // and every Cmd-Tab fired a fresh Keychain read + full book walk.
        if let stamp = model.lastAttemptAt ?? model.loadedAt,
           Date().timeIntervalSince(stamp) < minInterval { return }
        await model.load()
    }

    /// Re-fetch the book every 10 minutes while the app is open. The layout is
    /// deterministic, so only the data changes — each pass re-maps the fetch
    /// into `ABLeadsData`. Manual Refresh stays on the header.
    private func periodicRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)   // 10 minutes
            if Task.isCancelled { break }
            await model.load()
        }
    }

    // MARK: - Leads surface (re-skinned ABLeads, live data)

    // Renders `ABLeadsView` from the LIVE pipeline: DashboardViewModel fetches
    // Supabase (LeadsRepository → DashboardInputs, all v_cec_* views) and maps it
    // into `ABLeadsData`. The pinned strip rides on top; rows/pins open the shared
    // lead profile. Loadable states render distinctly (loading / error / stale) —
    // never a blank black screen. The `--screenshot` harness renders the FROZEN
    // fixture through this same view code (no network). (decision-log #16)
    @ViewBuilder
    private var leadsSurface: some View {
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
            onRefresh: fixture ? nil : { model.requestLoad() },
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
            model.requestLoad()
        }
    }
}
