import Foundation

/// The Leads tab's analytic lens: four independent dimensions, ANDed, each
/// single-select. `nil` on a dimension means "all".
///
/// This is a VALUE — the view model holds one, every number on the tab is
/// derived from it, and nothing is cached behind it. That is the whole contract:
/// the hero ratios, the trends, the breakdowns and the list are all computed
/// from the SAME filtered lead set, so a filtered view can never mix a filtered
/// list with unfiltered headline stats.
struct LeadFilter: Equatable, Sendable {
    /// Which personalization lane a lead went through.
    enum Lane: String, CaseIterable, Sendable {
        case deep       // ce-deepprep cohort (lead_enrichment.deep_cohort_run_id)
        case standard   // has a personalized opener, but no deep-lane run
        case none       // no opener written yet

        var label: String {
            switch self {
            case .deep:     return "Deep lane"
            case .standard: return "Standard personalization"
            // NOT "Not personalized": deep-lane leads keep their lane even when
            // their copy hasn't been written, so this bucket is standard-lane leads
            // with no opener — it does not list every lead lacking copy, and the
            // label must not promise that it does.
            case .none:     return "No opener yet"
            }
        }
    }

    var lane: Lane? = nil
    var region: String? = nil
    var source: String? = nil
    var industry: String? = nil

    static let all = LeadFilter()

    var isActive: Bool { self != .all }

    /// Human-readable one-line summary of the active dimensions ("Deep lane ·
    /// California"); nil when nothing is filtered.
    var summary: String? {
        let parts = [lane?.label, region, source, industry].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The same lens without its lane dimension — used when the lane reads failed,
    /// so the derivation can suppress a dimension it cannot compute WITHOUT the
    /// user's selection being rewritten (the bar keeps editing `filter`).
    func droppingLane() -> LeadFilter {
        LeadFilter(lane: nil, region: region, source: source, industry: industry)
    }

    /// Does one lead's derived facets pass every active dimension?
    /// Facet derivation lives in `LeadFacets` so the filter and the facet menus
    /// can never disagree about what a lead's region/source/industry IS.
    func matches(_ facets: LeadFacets) -> Bool {
        if let lane, facets.lane != lane { return false }
        if let region, facets.region != region { return false }
        if let source, facets.source != source { return false }
        if let industry, facets.industry != industry { return false }
        return true
    }
}

/// One lead reduced to the four filterable dimensions, plus the parsed timestamp
/// the trends bucket on. Derived ONCE per lead per snapshot (in
/// `LeadSnapshot.facets`) and reused by the filter test, the facet menus, the
/// breakdown panels AND the rendered row — one derivation, no drift.
///
/// The single-derivation rule is not tidiness. Two things depended on it: the row
/// used to label a null source "—" while the panel and the menu called the same
/// lead "Unknown" (two spellings of one value), and re-deriving per filter change
/// cost 46 ms at 1.5k leads and 414 ms at this repository's own 25k ceiling —
/// on the main actor, per menu pick.
struct LeadFacets: Equatable, Sendable {
    let lane: LeadFilter.Lane
    let region: String
    let source: String
    let industry: String
    /// Display label for the row's location column (not a filter dimension).
    let location: String
    /// `created_at`, parsed once. `ISO8601DateFormatter` costs ~60 µs a call and
    /// dominated the old per-derive cost.
    let createdAt: Date?

    /// Placeholder shown (and filterable) when a lead's column is null/blank. The
    /// row renders this same string, so clicking a menu option can never show rows
    /// labelled with a different word than the option that selected them.
    static let unknown = "Unknown"

    init(lead: LeadRow, deepLane: Bool, personalized: Bool) {
        // Deep is a PROVENANCE, not a state: a deep-cohort lead stays in the deep
        // lane even before its copy is written (9 of the 16 live deep leads have no
        // opener yet). The third bucket is therefore named for what it actually
        // tests — no opener, standard lane — rather than "not personalized", which
        // would read as a promise to list every lead lacking copy.
        self.lane = deepLane ? .deep : (personalized ? .standard : LeadFilter.Lane.none)
        self.region = RegionKey.region(city: lead.city, state: lead.state,
                                       location: lead.location, country: lead.country)
        self.source = lead.leadSource?.nilIfEmpty ?? Self.unknown
        self.industry = lead.industry?.nilIfEmpty ?? Self.unknown
        self.location = ABLeadsData.locationLabel(city: lead.city, state: lead.state,
                                                  location: lead.location)
        self.createdAt = DateParse.iso(lead.createdAt)
    }
}

/// A lead book plus everything derived from it that does NOT depend on the filter.
/// Built once per fetch; a filter change re-runs only the `matches` test and the
/// tallies over these values.
struct LeadSnapshot: Sendable {
    let inputs: DashboardInputs
    /// Parallel to `inputs.leads` — index i describes lead i. Built together in
    /// `init`, so the two can't drift apart.
    let facets: [LeadFacets]

    init(_ inputs: DashboardInputs) {
        self.inputs = inputs
        // Built through the same per-row derivation the search path uses, so a hit
        // and a list row can never be classified differently.
        self.facets = inputs.leads.map { row in
            LeadFacets(lead: row,
                       deepLane: inputs.deepLaneLeadIDs.contains(row.id),
                       personalized: inputs.personalizedLeadIDs.contains(row.id))
        }
    }

    /// Facets for ANY row, including one the snapshot doesn't contain (a search hit
    /// from beyond the fetched book). The id sets are the whole classification, so
    /// this is exact for rows in the book and correctly reports "no opener" only
    /// when the enrichment reads genuinely say so.
    func facets(for row: LeadRow) -> LeadFacets {
        LeadFacets(lead: row,
                   deepLane: inputs.deepLaneLeadIDs.contains(row.id),
                   personalized: inputs.personalizedLeadIDs.contains(row.id))
    }
}

/// The four facet menus, each already counted over the CURRENT lead set so the
/// user sees how many leads a choice would leave before making it.
struct FilterFacets: Sendable {
    struct Option: Identifiable, Sendable {
        let value: String
        let count: Int
        var id: String { value }
    }

    var lanes: [(lane: LeadFilter.Lane, count: Int)] = []
    var regions: [Option] = []
    var sources: [Option] = []
    var industries: [Option] = []

    /// Build every menu from one pass over the leads' facets.
    ///
    /// Counts are computed against the leads that pass the OTHER dimensions (the
    /// usual faceted-search rule), so a menu never offers a choice that would
    /// return zero rows, and the count beside each option is the number of leads
    /// selecting it would actually show.
    ///
    /// NOT truncated. An earlier cut kept the top 40 by count and dropped the tail
    /// silently — the live book derives ~84 region labels, so roughly half the
    /// region menu was unreachable and unnamed, and an absent facet reads as an
    /// absent population. A macOS menu scrolls; a missing bucket doesn't announce
    /// itself.
    static func build(_ facets: [LeadFacets], filter: LeadFilter) -> FilterFacets {
        func tally<T: Hashable>(_ dimension: KeyPath<LeadFacets, T>,
                                ignoring clear: (inout LeadFilter) -> Void) -> [T: Int] {
            var others = filter
            clear(&others)
            var counts: [T: Int] = [:]
            for f in facets where others.matches(f) { counts[f[keyPath: dimension], default: 0] += 1 }
            return counts
        }

        func options(_ counts: [String: Int], selected: String?) -> [Option] {
            var out = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { Option(value: $0.key, count: $0.value) }
            // The active value always appears in its own menu, even at count 0 —
            // otherwise a selection that another dimension emptied can be cleared
            // but never re-picked.
            if let selected, !out.contains(where: { $0.value == selected }) {
                out.append(Option(value: selected, count: 0))
            }
            return out
        }

        var out = FilterFacets()
        let laneCounts = tally(\.lane) { $0.lane = nil }
        out.lanes = LeadFilter.Lane.allCases.compactMap { lane in
            laneCounts[lane].map { (lane, $0) } ?? (lane == filter.lane ? (lane, 0) : nil)
        }
        out.regions = options(tally(\.region) { $0.region = nil }, selected: filter.region)
        out.sources = options(tally(\.source) { $0.source = nil }, selected: filter.source)
        out.industries = options(tally(\.industry) { $0.industry = nil }, selected: filter.industry)
        return out
    }
}
