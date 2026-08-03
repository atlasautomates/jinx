import Foundation
import Observation

/// Owns the Leads tab's search box: the typed query, the in-flight request, and
/// the hit list.
///
/// Search is a SERVER query against the whole `leads` table, deliberately not a
/// local filter over the loaded snapshot — the snapshot is capped, and "I can't
/// find the lead I know exists" is the one failure this feature cannot have. It is
/// also independent of the filter bar: filters are the analytic lens over the book,
/// search is a lookup, and silently returning nothing because a filter was left set
/// would be indistinguishable from the lead not existing.
@MainActor
@Observable
final class LeadSearchModel {
    /// What the user has typed. Not the same as the term that produced `state` —
    /// results stay on screen while the box is edited, until Enter is pressed again.
    var query: String = ""
    private(set) var state: SearchState = .idle

    enum SearchState {
        case idle
        case searching(term: String)
        case results(term: String, hits: [ABLeadsData.Lead])
        case failed(term: String, message: String)

        var isSearching: Bool { if case .searching = self { return true }; return false }
        /// The term whose outcome is on screen (nil when idle).
        var term: String? {
            switch self {
            case .idle: return nil
            case .searching(let t), .results(let t, _), .failed(let t, _): return t
            }
        }
    }

    /// The request in flight. Cancelled by the next one so a slow first query can
    /// never land after — and overwrite — the results of a later one.
    private var inFlight: Task<Void, Never>?

    /// Dev-only offline search (`--fixture`): same sanitizer, same result shape,
    /// no network. Set by `RootView` only when the flag is present.
    var fixtureRows: [LeadRow]? = nil

    /// Run the query currently in the box (Enter). A blank/too-short term clears
    /// rather than searching, so ⌫⌫⏎ puts the tab back the way it was.
    func submit(client: @escaping () throws -> SupabaseClient = { try SupabaseClient.make() }) {
        guard let term = LeadsRepository.searchTerm(query) else {
            clear()
            return
        }
        if let fixtureRows {
            inFlight?.cancel()
            state = .results(term: term,
                             hits: LeadsFixtureSource.search(term, in: fixtureRows)
                                 .map(ABLeadsData.lead))
            return
        }
        inFlight?.cancel()
        state = .searching(term: term)
        inFlight = Task { [weak self] in
            do {
                let repo = LeadsRepository(client: try client())
                let rows = try await repo.search(term)
                if Task.isCancelled { return }
                self?.state = .results(term: term, hits: rows.map(ABLeadsData.lead))
            } catch {
                if Task.isCancelled { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.state = .failed(term: term, message: message)
            }
        }
    }

    /// Drop the results and the query — the tab returns to its filtered view.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        query = ""
        state = .idle
    }
}
