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
    private var inFlight: Task<Void, Never>? {
        didSet { live.set(inFlight) }
    }

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
        inFlight?.cancel()
        inFlight = nil
        if let fixtureRows {
            state = .results(term: term,
                             hits: LeadsFixtureSource.search(term, in: fixtureRows)
                                 .map { ABLeadsData.lead($0) })
            return
        }
        state = .searching(term: term)
        inFlight = Task { [weak self] in
            do {
                // The client is built OFF the main actor: a `Task {}` inside a
                // @MainActor type inherits that isolation, so constructing it inline
                // ran the Keychain read on the main thread.
                let rows = try await Self.runSearch(term, client: client)
                if Task.isCancelled { return }
                self?.state = .results(term: term, hits: rows.map { ABLeadsData.lead($0) })
                self?.inFlight = nil
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.state = .failed(term: term, message: message)
                self?.inFlight = nil
            }
        }
    }

    private nonisolated static func runSearch(
        _ term: String, client: () throws -> SupabaseClient
    ) async throws -> [LeadRow] {
        try await LeadsRepository(client: try client()).search(term)
    }

    /// Drop the results and the query — the tab returns to its filtered view.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        query = ""
        state = .idle
    }

    /// A search outliving its window would hold a URLSession request open to its
    /// 30s resource ceiling. The handle lives in a box so `deinit` — which is
    /// nonisolated — can cancel it without touching main-actor state.
    private let live = TaskBox()
    deinit { live.cancel() }

    /// Nonisolated holder for the in-flight task handle.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        func set(_ t: Task<Void, Never>?) { lock.lock(); task = t; lock.unlock() }
        func cancel() { lock.lock(); let t = task; task = nil; lock.unlock(); t?.cancel() }
    }
}
