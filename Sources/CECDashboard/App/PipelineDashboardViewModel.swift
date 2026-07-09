import Foundation
import Observation

/// Owns the Pipeline tab's async state. Mirrors `CampaignDashboardViewModel`
/// (deterministic layout, no Haiku): fetch → compose → build, with the same
/// loading / loaded / stale / failed semantics — never a silent blank.
///
/// Adds `hasRunningRun`, which RootView's pipeline poll loop reads to switch
/// between the fast cadence (a run is live — stages should advance on screen)
/// and the idle 10-minute cadence.
@MainActor
@Observable
final class PipelineDashboardViewModel {
    private(set) var state: Loadable<Dashboard> = .idle
    private(set) var isRefreshing = false
    private(set) var hasRunningRun = false

    /// A 'running' run older than this is a PHANTOM (the ledger's documented
    /// stuck-row class), not a live run — it must not pin the fast poll cadence
    /// forever. Longest real runs are ~1-2h of stage budgets; 3h is generous.
    nonisolated static let runningLivenessWindow: TimeInterval = 3 * 3600

    /// True iff a run both says 'running' AND started recently enough to
    /// plausibly still be alive. Pure (no actor state) + injectable `now`,
    /// hence nonisolated — SelfTest calls it from a nonisolated context.
    nonisolated static func isLiveRunning(_ run: PipelineRunRow, now: Date = Date()) -> Bool {
        guard (run.status ?? "").lowercased() == "running" else { return false }
        guard let started = DateParse.iso(run.startedAt) else { return false }
        return now.timeIntervalSince(started) < runningLivenessWindow
    }

    func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = state.value
        if previous == nil { state = .loading }

        do {
            let client = try SupabaseClient.make()
            let repo = PipelineRepository(client: client)
            let inputs = try await repo.fetch()
            hasRunningRun = inputs.runs.contains { Self.isLiveRunning($0) }
            state = .loaded(PipelineBuilder.build(inputs))
        } catch {
            // Degrade to the idle cadence during an outage — a failing load
            // must not keep the 8s hammer going against a dead endpoint
            // (platform review). The next successful poll re-detects liveness.
            hasRunningRun = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let previous {
                state = .stale(previous, since: Date(), message: message)
            } else {
                state = .failed(message: message)
            }
        }
    }
}
