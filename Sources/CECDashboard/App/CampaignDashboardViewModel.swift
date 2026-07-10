import Foundation
import Observation

/// Owns the Campaigns tab's async state. Mirrors `DashboardViewModel` but simpler:
/// the layout is deterministic (built in `CampaignBuilder`), so there's no if-changed
/// layout gate — just fetch → compose → render, with the same
/// loading / loaded / stale / failed semantics (never a silent blank).
@MainActor
@Observable
final class CampaignDashboardViewModel {
    private(set) var state: Loadable<Dashboard> = .idle
    private(set) var isRefreshing = false

    func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = state.value
        if previous == nil { state = .loading }

        do {
            let client = try SupabaseClient.make()
            let repo = CampaignsRepository(client: client)
            let inputs = try await repo.fetch()
            state = .loaded(CampaignBuilder.build(inputs))
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
