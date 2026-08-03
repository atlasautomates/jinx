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

    /// The last successful fetch, kept so a filter change is a local re-derivation
    /// rather than a network round trip.
    private var snapshot: DashboardInputs?

    /// Dev-only offline load (`--fixture`): the same map/filter path over a
    /// synthetic book, so the LIVE window can be driven without Keychain or
    /// network. Never reachable in a normal launch — `RootView` calls it only
    /// when the flag is present.
    func loadFixture() {
        let inputs = LeadsFixtureSource.inputs()
        snapshot = inputs
        state = .loaded(ABLeadsData(inputs: inputs, filter: filter))
    }

    /// The loaded lead rows (fixture search runs against these).
    var snapshotLeads: [LeadRow] { snapshot?.leads ?? [] }

    /// Fetch + map. Keeps the last good value on screen during a refresh, and
    /// degrades to `.stale` (data + reason) rather than `.failed` if one was present.
    /// The layout is fully deterministic (same shape as the Campaigns/Pipeline tabs);
    /// only the data changes on refresh.
    func load() async {
        // In-flight guard: overlapping loads (double-click, retry during a slow fetch)
        // would race on `state` and could clobber fresh data with an older response.
        // Race-free because the VM is @MainActor.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = state.value
        if previous == nil { state = .loading }

        do {
            let client = try SupabaseClient.make()
            let repo = LeadsRepository(client: client)
            let inputs = try await repo.fetch()
            snapshot = inputs
            state = .loaded(ABLeadsData(inputs: inputs, filter: filter))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let previous {
                state = .stale(previous, since: Date(), message: message)
            } else {
                state = .failed(message: message)
            }
        }
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
        let mapped = ABLeadsData(inputs: snapshot, filter: filter)
        switch state {
        case .stale(_, let since, let message):
            state = .stale(mapped, since: since, message: message)
        case .loaded, .loading, .idle, .failed:
            state = .loaded(mapped)
        }
    }
}
