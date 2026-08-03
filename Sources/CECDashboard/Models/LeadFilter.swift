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
            case .none:     return "Not personalized"
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

/// One lead reduced to the four filterable dimensions. Derived ONCE per lead per
/// snapshot (in `LeadsSnapshot.facets`), then reused by the filter test, the
/// facet menus and the breakdown panels — one derivation, no drift.
struct LeadFacets: Equatable, Sendable {
    let lane: LeadFilter.Lane
    let region: String
    let source: String
    let industry: String

    /// Placeholder shown (and filterable) when a lead's column is null/blank.
    static let unknown = "Unknown"

    init(lead: LeadRow, deepLane: Bool, personalized: Bool) {
        // Deep wins over standard: a deep-lane lead also has an opener, and the
        // question the lane filter answers is "which lane produced this copy?".
        self.lane = deepLane ? .deep : (personalized ? .standard : LeadFilter.Lane.none)
        self.region = RegionKey.region(city: lead.city, state: lead.state,
                                       location: lead.location, country: lead.country)
        self.source = lead.leadSource?.nilIfEmpty ?? Self.unknown
        self.industry = lead.industry?.nilIfEmpty ?? Self.unknown
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
    static func build(_ facets: [LeadFacets], filter: LeadFilter, topN: Int = 40) -> FilterFacets {
        func tally<T: Hashable>(_ dimension: KeyPath<LeadFacets, T>,
                                ignoring clear: (inout LeadFilter) -> Void) -> [T: Int] {
            var others = filter
            clear(&others)
            var counts: [T: Int] = [:]
            for f in facets where others.matches(f) { counts[f[keyPath: dimension], default: 0] += 1 }
            return counts
        }

        func options(_ counts: [String: Int]) -> [Option] {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(topN)
                .map { Option(value: $0.key, count: $0.value) }
        }

        var out = FilterFacets()
        let laneCounts = tally(\.lane) { $0.lane = nil }
        out.lanes = LeadFilter.Lane.allCases.compactMap { lane in
            laneCounts[lane].map { (lane, $0) }
        }
        out.regions = options(tally(\.region) { $0.region = nil })
        out.sources = options(tally(\.source) { $0.source = nil })
        out.industries = options(tally(\.industry) { $0.industry = nil })
        return out
    }
}
