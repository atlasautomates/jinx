import Foundation
import Observation

/// Owns the Leads tab's async state. Fetches the live lead pipeline, maps it into
/// the re-skinned `ABLeadsData` shape, and exposes a `Loadable` so the view renders
/// loading / loaded / stale / failed distinctly (never a silent blank).
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var state: Loadable<ABLeadsData> = .idle
    /// True while a `load()` is in flight — drives the Refresh affordance's spinner
    /// and disabled state.
    private(set) var isRefreshing = false

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
            state = .loaded(ABLeadsData(inputs: inputs))
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
