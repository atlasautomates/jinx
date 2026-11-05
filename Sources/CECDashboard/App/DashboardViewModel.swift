import Foundation
import Observation

/// Owns the Leads tab's async state. Fetches the live lead pipeline, maps it into
/// the re-skinned `ABLeadsData` shape, and exposes a `Loadable` so the view renders
/// loading / loaded / stale / failed distinctly (never a silent blank).
///
/// The filter lives here too, beside the snapshot it re-derives: changing a filter
/// re-maps the lead book already in memory instead of re-querying Supabase. That is
/// what makes the hero stats move the instant a menu changes, and it is why the
/// repository fetches the whole book rather than a recency window.
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var state: Loadable<ABLeadsData> = .idle
    /// True while a `load()` is in flight — drives the Refresh affordance's spinner
    /// and disabled state.
    private(set) var isRefreshing = false
    /// The active lens. Set through `apply(_:)` so the derived view can never lag
    /// behind the filter the bar is drawing.
    private(set) var filter: LeadFilter = .all
    /// When a load was last ATTEMPTED (success or not). The wake/activation
    /// throttle floors on this, not on `loadedAt` — success-only stamping made
    /// the throttle vacuous exactly while loads were failing (no credential,
    /// expired JWT), so every Cmd-Tab fired a fresh Keychain read + full walk
    /// (contention lens).
    private(set) var lastAttemptAt: Date? = nil
    /// When the data currently on screen was fetched.
    ///
    /// Owned HERE, and written only on the success path, because the header stamp
    /// exists solely to state the data's age. Set from the call sites it was wrong
    /// twice over: two of the five refresh drivers wrote it (the manual Refresh
    /// button and the 10-minute poll did not), and they wrote it BEFORE awaiting the
    /// fetch — so a refresh that was deduped, cancelled or failed still advanced the
    /// clock over unchanged data. That is precisely the lie the stamp was added to
    /// prevent.
    private(set) var loadedAt: Date? = nil

    /// The last successful fetch, with its per-lead facets already derived, so a
    /// filter change is a local re-tally rather than a re-derivation (which cost
    /// 46 ms at today's book size and 414 ms at the repository's page ceiling —
    /// on the main actor, per menu pick).
    private var snapshot: LeadSnapshot?

    /// Where a load gets its data. Injectable ONLY so `--selftest` can drive the
    /// real `load()` — its failure, cancellation and reentrancy branches were
    /// unreachable while this hard-called `SupabaseClient.make()`, which is how a
    /// reported-and-fixed defect (the freshness stamp advancing on a failed load)
    /// could be reinstated verbatim and still pass a green suite.
    typealias Fetcher = @Sendable () async throws -> DashboardInputs
    private let fetcher: Fetcher

    init(fetcher: @escaping Fetcher = DashboardViewModel.liveFetch) {
        self.fetcher = fetcher
    }

    /// Dev-only offline load: the same map/filter path over a synthetic book, so the
    /// LIVE window can be driven without Keychain or network. Debug builds only —
    /// see `LeadsFixtureSource`.
    func loadFixture() { loadOffline(LeadsFixtureSource.inputs()) }

    /// `--demo` (#113): the synthetic solar showcase book, same derivation path.
    func loadDemo() { loadOffline(DemoBook.inputs()) }

    /// Shared body of the two offline books: no network, same derivation.
    private func loadOffline(_ inputs: DashboardInputs) {
        let snap = LeadSnapshot(inputs)
        snapshot = snap
        loadedAt = Date()
        state = .loaded(ABLeadsData(snapshot: snap, filter: filter))
    }

    /// The loaded lead rows (fixture search runs against these).
    var snapshotLeads: [LeadRow] { snapshot?.inputs.leads ?? [] }

    /// Classifies any row into filter dimensions using this load's enrichment id
    /// sets — so a search hit is filtered by exactly the derivation the list uses.
    /// nil with no snapshot: the filter then cannot be evaluated, and the search
    /// panel says so instead of quietly showing everything.
    var facetResolver: ((LeadRow) -> LeadFacets)? {
        guard let snapshot else { return nil }
        return { snapshot.facets(for: $0) }
    }

    /// Fetch + map. Keeps the last good value on screen during a refresh, and
    /// degrades to `.stale` (data + reason) rather than `.failed` if one was present.
    /// The layout is fully deterministic (same shape as the Campaigns/Pipeline tabs);
    /// only the data changes on refresh.
    func load() async {
        // In-flight guard: overlapping loads (double-click, retry during a slow fetch)
        // would race on `state` and could clobber fresh data with an older response.
        // Race-free because the VM is @MainActor and there is no await between the
        // check and the set.
        guard !isRefreshing else { return }
        isRefreshing = true
        lastAttemptAt = Date()
        defer { isRefreshing = false }

        if state.value == nil { state = .loading }

        do {
            let inputs = try await fetcher()
            let snap = LeadSnapshot(inputs)
            snapshot = snap
            loadedAt = Date()          // success only — see the property's note
            state = .loaded(ABLeadsData(snapshot: snap, filter: filter))
        } catch is CancellationError {
            // The window is going away (or a newer load superseded us). Writing a
            // stale banner on the way out would report teardown as a network fault.
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Re-derive from what is CURRENT rather than reusing a value captured
            // before the await: `@MainActor` is reentrant, so the user can change a
            // filter while this fetch is suspended, and writing back the pre-change
            // data would silently revert their pick.
            if let snapshot {
                state = .stale(ABLeadsData(snapshot: snapshot, filter: filter),
                               since: Date(), message: message)
            } else {
                state = .failed(message: message)
            }
        }
    }

    /// The production fetch, hoisted out of the main actor.
    ///
    /// `nonisolated` is load-bearing: an unstructured `Task {}` created inside a
    /// `@MainActor` type INHERITS that isolation (SE-0304), so building the client
    /// inline ran `SecItemCopyMatching` — a synchronous Security-framework call that
    /// can block, and can prompt — on the main thread.
    @Sendable nonisolated static func liveFetch() async throws -> DashboardInputs {
        let client = try SupabaseClient.make()
        return try await LeadsRepository(client: client).fetch()
    }

    /// Event-entry-point refresh: a STORED, cancel-and-replace task, so a
    /// window closed mid-refresh doesn't strand an unowned task holding a
    /// URLSession request to its 30 s resource ceiling. Full parity with
    /// LeadSearchModel.inFlight (delta round 2): the nonisolated TaskBox lets
    /// `deinit` cancel the in-flight request when the window closes, and the
    /// identity-guarded nil-out stops a finishing task from clearing its
    /// SUCCESSOR's handle (which would make the successor uncancellable).
    private var refreshTask: Task<Void, Never>? {
        didSet { liveRefresh.set(refreshTask) }
    }
    private var refreshGeneration = 0
    func requestLoad() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let gen = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.load()
            // Identity-guarded: only the CURRENT generation may clear the
            // handle — a superseded task nulling it made its successor
            // uncancellable.
            if let self, self.refreshGeneration == gen { self.refreshTask = nil }
        }
    }

    private let liveRefresh = TaskBox()
    deinit { liveRefresh.cancel() }

    /// Nonisolated holder so `deinit` (nonisolated) can cancel without touching
    /// main-actor state — the LeadSearchModel pattern.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        func set(_ t: Task<Void, Never>?) { lock.lock(); task = t; lock.unlock() }
        func cancel() { lock.lock(); let t = task; task = nil; lock.unlock(); t?.cancel() }
    }

    /// Apply a new lens and re-derive every figure from the snapshot in memory.
    ///
    /// A filter change never clears the screen and never refetches: with no snapshot
    /// yet (first load still in flight, or it failed) it only records the choice, and
    /// the next successful load maps through it.
    func apply(_ newFilter: LeadFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        remap()
    }

    /// Re-derive the on-screen data through the current filter, PRESERVING the
    /// `Loadable` case: a stale banner has to survive a filter change, because the
    /// data really is still stale — re-deriving it doesn't make it fresh.
    private func remap() {
        guard let snapshot else { return }
        let mapped = ABLeadsData(snapshot: snapshot, filter: filter)
        switch state {
        case .stale(_, let since, let message):
            state = .stale(mapped, since: since, message: message)
        case .loaded, .loading, .idle, .failed:
            state = .loaded(mapped)
        }
    }
}
