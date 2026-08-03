import Foundation
import Observation

/// Owns the Leads tab's search box: the typed query, the in-flight request, and
/// the hit list.
///
/// The QUERY is always against the whole `leads` table, never the loaded snapshot —
/// the snapshot is capped, and "I can't find the lead I know exists" is the one
/// failure this feature cannot have. The RESULTS are then narrowed by whatever
/// filter the tab has applied, so the search box answers the same question as the
/// rest of the screen. The two are deliberately separated: anything the filter hides
/// is COUNTED and offered ("+3 outside this filter"), so a hidden lead never reads
/// as a missing one.
@MainActor
@Observable
final class LeadSearchModel {
    /// What the user has typed. Not the same as the term that produced `state` —
    /// results stay on screen while the box is edited, until Enter is pressed again.
    var query: String = ""
    private(set) var state: SearchState = .idle
    /// The lens results are narrowed by — the tab's APPLIED filter, pushed in by
    /// `RootView` whenever it changes or a load lands.
    private(set) var scope: LeadFilter = .all
    /// Set by the user to see every hit regardless of the filter. Resets whenever a
    /// new search is submitted, so it is a per-look-up escape hatch and not a mode
    /// someone can leave on and forget.
    private(set) var ignoringFilters = false

    enum SearchState {
        case idle
        case searching(term: String)
        /// `hiddenByFilter` = hits the query found that the current lens excludes.
        case results(term: String, hits: [ABLeadsData.Lead], hiddenByFilter: Int)
        case failed(term: String, message: String)

        var isSearching: Bool { if case .searching = self { return true }; return false }
        /// The term whose outcome is on screen (nil when idle).
        var term: String? {
            switch self {
            case .idle: return nil
            case .searching(let t), .results(let t, _, _), .failed(let t, _): return t
            }
        }
    }

    /// The request in flight. Cancelled by the next one so a slow first query can
    /// never land after — and overwrite — the results of a later one.
    private var inFlight: Task<Void, Never>? {
        didSet { live.set(inFlight) }
    }

    /// Raw hits, kept so a filter change re-narrows them without re-querying.
    private var rawHits: [LeadRow] = []
    /// Classifies a row into filter dimensions. nil when there is no snapshot (the
    /// load failed) — the filter then cannot be applied and the panel says so rather
    /// than silently showing everything as if it had been.
    private var facetsFor: ((LeadRow) -> LeadFacets)? = nil

    /// Dev-only offline search (`--fixture`): same sanitizer, same result shape,
    /// no network. Set by `RootView` only when the flag is present.
    var fixtureRows: [LeadRow]? = nil

    /// Push the tab's applied lens in. Re-narrows anything already on screen, so
    /// changing a filter with results up updates them in place.
    func updateScope(filter: LeadFilter, facets: ((LeadRow) -> LeadFacets)?) {
        scope = filter
        facetsFor = facets
        refilter()
    }

    /// Show every hit for the CURRENT term, filter or not.
    func setIgnoringFilters(_ ignoring: Bool) {
        guard ignoring != ignoringFilters else { return }
        ignoringFilters = ignoring
        refilter()
    }

    /// Run the query currently in the box (Enter). A blank/too-short term clears
    /// rather than searching, so ⌫⌫⏎ puts the tab back the way it was.
    func submit(client: @escaping () throws -> SupabaseClient = { try SupabaseClient.make() }) {
        guard let term = LeadsRepository.searchTerm(query) else {
            // Dismiss the RESULTS, keep the text. Routing this to `clear()` deleted
            // what the user had typed: backspacing to one character and pressing
            // Enter wiped the box.
            dismissResults()
            return
        }
        inFlight?.cancel()
        inFlight = nil
        ignoringFilters = false   // a new look-up starts inside the current lens
        if let fixtureRows {
            publish(term: term, rows: LeadsFixtureSource.search(term, in: fixtureRows))
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
                self?.publish(term: term, rows: rows)
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

    /// Store the raw hits and render them through the current lens.
    private func publish(term: String, rows: [LeadRow]) {
        rawHits = rows
        state = Self.narrow(term: term, rows: rows, scope: scope,
                            facets: facetsFor, ignoring: ignoringFilters)
    }

    /// Re-narrow what is already on screen (filter changed, or the escape hatch
    /// toggled). No-op unless results are showing.
    private func refilter() {
        guard case .results(let term, _, _) = state else { return }
        state = Self.narrow(term: term, rows: rawHits, scope: scope,
                            facets: facetsFor, ignoring: ignoringFilters)
    }

    /// PURE (selftest target): split hits into shown and hidden-by-filter.
    ///
    /// With no facet resolver the filter cannot be evaluated, so nothing is hidden —
    /// showing fewer leads than exist because we couldn't classify them would be the
    /// silent-omission failure this whole feature is built to avoid.
    static func narrow(term: String, rows: [LeadRow], scope: LeadFilter,
                       facets: ((LeadRow) -> LeadFacets)?, ignoring: Bool) -> SearchState {
        guard scope.isActive, !ignoring, let facets else {
            return .results(term: term, hits: rows.map { ABLeadsData.lead($0) }, hiddenByFilter: 0)
        }
        var shown: [ABLeadsData.Lead] = []
        var hidden = 0
        for row in rows {
            let f = facets(row)
            if scope.matches(f) { shown.append(ABLeadsData.lead(row, facets: f)) } else { hidden += 1 }
        }
        return .results(term: term, hits: shown, hiddenByFilter: hidden)
    }

    /// Drop the results and the query — the tab returns to its filtered view.
    func clear() {
        dismissResults()
        query = ""
    }

    /// Drop the results but keep what the user typed.
    func dismissResults() {
        inFlight?.cancel()
        inFlight = nil
        rawHits = []
        ignoringFilters = false
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
