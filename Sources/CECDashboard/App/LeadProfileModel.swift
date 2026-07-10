import Foundation
import Observation

/// App-wide profile presentation seam: any surface (Leads list, campaign
/// roster, Pipeline inspector) sets `active` and RootView presents the sheet.
/// One seam, three entry points — the tabs never own their own sheet state.
@MainActor
@Observable
final class ProfilePresenter {
    var active: LeadRef?
}

/// Async state for one profile render. Same newest-wins generation discipline
/// as `LeadInspectorModel` — a stale fetch can't land under a newer lead.
@MainActor
@Observable
final class LeadProfileModel {
    private(set) var inputs: ProfileInputs?
    private(set) var isLoading = false
    private(set) var message: String?
    private var generation = 0

    func load(_ ref: LeadRef) async {
        generation += 1
        let gen = generation
        inputs = nil
        message = nil
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let repo = ProfileRepository(client: try SupabaseClient.make())
            let fetched = try await repo.fetch(ref)
            guard gen == generation else { return }   // superseded
            inputs = fetched
        } catch {
            // Task.isCancelled: sheet dismissed mid-load (.task cancellation
            // arrives as a wrapped URLError, not CancellationError) — a normal
            // close must never paint a "cancelled" error (swift-semantics).
            guard gen == generation, !Task.isCancelled else { return }
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
