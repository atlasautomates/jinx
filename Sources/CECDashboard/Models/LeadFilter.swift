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
        case deep       // deepening elected (lead_status.deepening ≠ 'none')
        case standard   // campaign-ready copy exists, but no deepening election
        case none       // no send-ready copy yet

        var label: String {
            switch self {
            case .deep:     return "Deep lane"
            case .standard: return "Standard personalization"
            // NOT "Not personalized": deep-lane leads keep their lane even when
            // their copy hasn't been written, so this bucket is standard-lane leads
            // with no send-ready copy — it does not list every lead lacking copy,
            // and the label must not promise that it does.
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
/// the trends bucket on and the derived pipeline stage the row displays. Derived
/// ONCE per lead per snapshot (in `LeadSnapshot`) and reused by the filter test,
/// the facet menus, the breakdown panels AND the rendered row — one derivation,
/// no drift.
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
    /// The furthest pipeline stage this lead provably reached — display
    /// vocabulary shared with the funnel rollup ("Scraped" / "Researched" /
    /// "Personalized" / "Campaigned"), promoted to "Replied" when an inbound
    /// email is on record (the reward outcome must stay visible in the list —
    /// design review, 7.2). See `stage(lead:emailed:replied:)`.
    let stage: String
    /// `created_at`, parsed once. `ISO8601DateFormatter` costs ~60 µs a call and
    /// dominated the old per-derive cost.
    let createdAt: Date?

    /// Placeholder shown (and filterable) when a lead's column is null/blank. The
    /// row renders this same string, so clicking a menu option can never show rows
    /// labelled with a different word than the option that selected them.
    static let unknown = "Unknown"

    /// `emailed` = this lead appears in the sent-event log (7.2: the permanent
    /// `v_cec_sent_events` record is the emailed truth — NOT the `outreach` axis,
    /// which diverges from it on 41 live leads whose only send bounced; diagnosed
    /// finding on the plan). `replied` = an inbound email is on record.
    init(lead: LeadRow, emailed: Bool, replied: Bool = false) {
        // Deep is a PROVENANCE, not a state: the deepening ELECTION keeps a lead
        // in the deep lane even before its copy is written. A nil axis (no
        // lead_status row — `statusRowMissing`) classifies as not-elected: that
        // is a judgment this derivation layer makes for display, not a value we
        // pretend the database wrote.
        let deep = lead.deepening.map { $0 != "none" } ?? false
        let personalized = lead.personalized == true
        self.lane = deep ? .deep : (personalized ? .standard : LeadFilter.Lane.none)
        self.region = RegionKey.region(city: lead.city, state: lead.state,
                                       location: lead.location, country: lead.country)
        self.source = lead.leadSource?.nilIfEmpty ?? Self.unknown
        self.industry = lead.industry?.nilIfEmpty ?? Self.unknown
        self.location = ABLeadsData.locationLabel(city: lead.city, state: lead.state,
                                                  location: lead.location)
        self.stage = Self.stage(lead: lead, emailed: emailed, replied: replied)
        self.createdAt = DateParse.iso(lead.createdAt)
    }

    /// Furthest-stage derivation (one spelling, shared by the row label and the
    /// funnel inputs): Replied (an inbound email exists — the reward outcome,
    /// past Campaigned) > Campaigned (a send is on record) > Personalized
    /// (campaign-ready copy — the view's guarded copy of the one method) >
    /// Researched (a dossier exists) > Scraped (in the book at all).
    static func stage(lead: LeadRow, emailed: Bool, replied: Bool = false) -> String {
        if replied { return "Replied" }
        if emailed { return "Campaigned" }
        if lead.personalized == true { return "Personalized" }
        if lead.hasResearch == true { return "Researched" }
        return "Scraped"
    }

    /// The `outreach`-axis fallback for "was this lead emailed" — used ONLY when
    /// the sent-events read degraded (see `LeadSnapshot`): an empty event set is
    /// then a READ FAILURE, not a fact about the book, and deriving every row's
    /// stage from it would relabel every campaigned lead "Personalized" — the
    /// exact misclassification class the old lane-degradation guard existed to
    /// prevent (swift-semantics review, 7.2).
    static func emailedPerAxis(_ lead: LeadRow) -> Bool {
        switch lead.outreach {
        case "in_sequence", "sequence_done", "replied": return true
        default: return false
        }
    }
}

/// A lead book plus everything derived from it that does NOT depend on the filter.
/// Built once per fetch; a filter change re-runs only the `matches` test and the
/// tallies over these values.
struct LeadSnapshot: Sendable {
    let inputs: DashboardInputs
    /// DISTINCT leads with at least one send on record — derived once from the
    /// sent-event log, consumed by the facet derivation, the emailed KPI and the
    /// funnel rollup, so the three can never disagree.
    let emailedLeadIDs: Set<String>
    /// True when the sent-events read FAILED: `emailedLeadIDs` is then empty (or
    /// a floor) because of the failure, not the book, and every emailed test in
    /// this snapshot falls back to the `outreach` axis instead — approximate,
    /// but never "everyone is unemailed".
    let sentEventsDegraded: Bool
    /// Parallel to `inputs.leads` — index i describes lead i. Built together in
    /// `init`, so the two can't drift apart.
    let facets: [LeadFacets]
    /// Leads whose `status_row_missing` flag is set — a broken write-path
    /// invariant p7a5 surfaces expressly so a NULL axis can't masquerade as a
    /// state; the tab's note area discloses the count.
    let statusRowsMissing: Int

    init(_ inputs: DashboardInputs) {
        self.inputs = inputs
        let emailed = Set(inputs.messagedSends.map(\.leadID))
        self.emailedLeadIDs = emailed
        let degraded = inputs.degradedReads.contains("outreach history")
        self.sentEventsDegraded = degraded
        // Built through the same per-row derivation the search path uses, so a hit
        // and a list row can never be classified differently.
        self.facets = inputs.leads.map { row in
            LeadFacets(lead: row,
                       emailed: degraded ? LeadFacets.emailedPerAxis(row)
                                         : emailed.contains(row.id),
                       replied: inputs.repliedLeadIDs.contains(row.id))
        }
        self.statusRowsMissing = inputs.leads.count(where: { $0.statusRowMissing == true })
    }

    /// Facets for ANY row, including one the snapshot doesn't contain (a search hit
    /// from beyond the fetched book). Lane/stage inputs ride the row itself
    /// (`v_cec_leads` axes) plus the sent-event and replied sets, so this is exact
    /// for any row the search select returns.
    func facets(for row: LeadRow) -> LeadFacets {
        LeadFacets(lead: row,
                   emailed: sentEventsDegraded ? LeadFacets.emailedPerAxis(row)
                                               : emailedLeadIDs.contains(row.id),
                   replied: inputs.repliedLeadIDs.contains(row.id))
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
