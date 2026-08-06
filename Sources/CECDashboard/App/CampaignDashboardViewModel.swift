import Foundation
import Observation

/// Owns the Campaigns tab's top-level async state: the composed campaign list
/// (`CampaignInputs`) behind the drill-down's level 1. Mirrors
/// `DashboardViewModel`'s loading / loaded / stale / failed semantics (never a
/// silent blank); drill levels 2–3 live in `CampaignDrillModel`.
@MainActor
@Observable
final class CampaignDashboardViewModel {
    private(set) var state: Loadable<CampaignInputs> = .idle
    private(set) var isRefreshing = false

    /// The composed summaries behind the campaign list (level 1 rows).
    var summaries: [CampaignSummary] { state.value?.summaries ?? [] }

    func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = state.value
        if previous == nil { state = .loading }

        do {
            let client = try SupabaseClient.make()
            let repo = CampaignsRepository(client: client)
            state = .loaded(try await repo.fetch())
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
