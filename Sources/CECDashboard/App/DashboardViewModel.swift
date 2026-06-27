import Foundation
import Observation

/// Owns the dashboard's async state. Fetches leads, builds the dashboard, and
/// exposes a `Loadable` so the view renders loading / loaded / stale / failed
/// distinctly (never a silent blank).
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var state: Loadable<Dashboard> = .idle
    /// True while a `load()` is in flight — drives the Refresh button's disabled state.
    private(set) var isRefreshing = false

    /// Fetch + rebuild. Keeps the last good value on screen during a refresh, and
    /// degrades to `.stale` (data + reason) rather than `.failed` if one was present.
    ///
    /// The LAYOUT goes through the if-changed gate: open / refresh / hourly all call
    /// this with `force: false`, so the layout only regenerates when the data profile
    /// shifts (data still re-fetches every call). `force: true` (the Re-layout button,
    /// step C) bypasses the gate. In step B the generator is the deterministic default
    /// plan; step C swaps in the Haiku call.
    func load(force: Bool = false) async {
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
            // Independent reads run concurrently (halves cold-load latency); a throw on
            // either fails the whole load, keeping the dashboard coherent (never half-built).
            // Total is exact (whole table); the window feeds the breakdown widgets.
            // Essential reads (throw → fail the load) + supplementary tier/sentiment
            // reads (fail-open to [:], so a missing RLS policy never fails the dashboard).
            async let total = repo.totalCount()
            async let leads = repo.recentLeads()
            async let tiers = repo.tierCounts()
            async let sentiment = repo.sentimentCounts()
            let inputs = DashboardInputs(
                leads: try await leads,
                totalCount: try await total,
                tierCounts: await tiers,
                sentimentCounts: await sentiment
            )

            // If-changed gate: reuse the cached plan unless the data profile changed;
            // on a miss, generate via Haiku (validated + fail-closed in the resolver).
            let profile = DataProfile.from(inputs)
            let plan = await LayoutResolver.resolvePlan(profile: profile, force: force) { p in
                await LayoutEngine.generatePlan(profile: p)
            }
            state = .loaded(DashboardBuilder.compose(inputs, plan: plan))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let previous {
                state = .stale(previous, since: Date(), message: message)
            } else {
                state = .failed(message: message)
            }
        }
    }
}
