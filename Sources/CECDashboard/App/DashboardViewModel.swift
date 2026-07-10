import Foundation
import Observation

/// Owns the dashboard's async state. Fetches leads, builds the dashboard, and
/// exposes a `Loadable` so the view renders loading / loaded / stale / failed
/// distinctly (never a silent blank).
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var state: Loadable<Dashboard> = .idle
    /// The fetched lead rows behind the dashboard — feeds the native clickable
    /// RecentLeadsList (P3), which replaced the recent-leads table widget.
    private(set) var recentLeads: [LeadRow] = []
    /// True while a `load()` is in flight — drives the Refresh button's disabled state.
    private(set) var isRefreshing = false

    /// Fetch + rebuild. Keeps the last good value on screen during a refresh, and
    /// degrades to `.stale` (data + reason) rather than `.failed` if one was present.
    /// Layout is fully deterministic (same shape as the Campaigns/Pipeline tabs).
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
            recentLeads = inputs.leads
            state = .loaded(DashboardBuilder.build(inputs))
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
