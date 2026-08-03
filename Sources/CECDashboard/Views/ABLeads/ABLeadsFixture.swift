import Foundation

// FROZEN A/B FIXTURE — mirrors AB-ARM/ab-fixture.json EXACTLY. Synthetic, no
// PII, no network, no Supabase. Both arms render this identical data. Embedded
// as an in-memory Swift value so the Leads tab renders deterministically.

struct ABLeadsData: Sendable {
    struct Totals { let scraped: Int; let emailed: Int; let replies: Int }
    struct Series { let weeks: [String]; let values: [Int] }
    struct Breakdown: Identifiable { let label: String; let count: Int; var id: String { label } }
    struct Lead: Identifiable {
        // DB id — nil for the frozen fixture; set from the live pipeline so a row
        // tap can open the lead profile. Identity prefers it (unique per lead);
        // the fixture falls back to `company` (unique within the fixture).
        var leadID: String? = nil
        let company: String; let industry: String; let location: String
        let source: String; let status: String; let added: String
        var firstName: String? = nil
        var id: String { leadID ?? company }
    }

    let totals: Totals
    let emailedOfScrapedPct: Double
    let repliesOfEmailedPct: Double
    let leadsAddedWeekly: Series
    let leadsMessagedWeekly: Series
    let bySource: [Breakdown]
    let byIndustry: [Breakdown]
    let byStatus: [Breakdown]
    let recentLeads: [Lead]
    /// Denominator behind `emailedOfScrapedPct` — normally `totals.scraped` (exact),
    /// but the windowed fallback (exact stage read failed) narrows it to the fetched
    /// window so the hero ratio stays leads/leads at one grain. nil in the fixture.
    var emailedDenominator: Int? = nil
    /// "N of M" when the breakdowns are computed over a fetched window smaller than
    /// the true total — surfaced so a windowed slice is never presented as a
    /// full-table total. nil (no note) in the fixture / when complete.
    var breakdownScopeNote: String? = nil

    // MARK: - Filtering (leads-filter)

    /// Where each lead sits geographically (derived — see `RegionKey`).
    var byRegion: [Breakdown] = []
    /// The lens currently applied. Every figure above is computed from the leads
    /// that pass it — there is no path that mixes a filtered list with unfiltered
    /// headline stats.
    var filter: LeadFilter = .all
    /// Menu contents for the filter bar, counted over the current lead set.
    var facets: FilterFacets = FilterFacets()
    /// False when the lane reads failed — the lane menu hides rather than claim
    /// every lead is "Not personalized".
    var laneFilterAvailable: Bool = true
    /// Leads passing the filter (the list is capped; this is the honest total).
    var matchingCount: Int = 0
    /// True when a supplementary read degraded this load.
    var partial: Bool = false

    /// Rows the recent-leads list renders at most. The list is lazy, but every row
    /// is an interactive, hoverable view — past a few hundred the scroll cost is
    /// real and nobody reads row 900. The header states the cap when it bites.
    static let listCap = 300

    static let ab = ABLeadsData(
        totals: .init(scraped: 1240, emailed: 861, replies: 74),
        emailedOfScrapedPct: 69.4,
        repliesOfEmailedPct: 8.6,
        leadsAddedWeekly: .init(
            weeks: ["May 4","May 11","May 18","May 25","Jun 1","Jun 8","Jun 15","Jun 22","Jun 29","Jul 6","Jul 13","Jul 20"],
            values: [34,41,52,48,61,75,58,66,82,91,77,88]),
        leadsMessagedWeekly: .init(
            weeks: ["May 4","May 11","May 18","May 25","Jun 1","Jun 8","Jun 15","Jun 22","Jun 29","Jul 6","Jul 13","Jul 20"],
            values: [20,28,35,33,47,51,44,50,63,70,58,67]),
        bySource: [
            .init(label: "Sales Navigator", count: 512),
            .init(label: "Google Maps", count: 388),
            .init(label: "Apollo", count: 204),
            .init(label: "Job Signals", count: 136),
        ],
        byIndustry: [
            .init(label: "Assisted Living", count: 296),
            .init(label: "Residential Solar", count: 248),
            .init(label: "Biotech", count: 183),
            .init(label: "EV Dealers", count: 187),
            .init(label: "Credit Unions", count: 174),
            .init(label: "Web Agencies", count: 152),
        ],
        byStatus: [
            .init(label: "Scraped", count: 379),
            .init(label: "Enriched", count: 240),
            .init(label: "Personalized", count: 160),
            .init(label: "Emailed", count: 285),
            .init(label: "Replied", count: 74),
            .init(label: "Bounced", count: 42),
            .init(label: "Do not contact", count: 60),
        ],
        recentLeads: [
            .init(company: "Ostrowen Senior Care", industry: "Assisted Living", location: "Tampa, FL", source: "Google Maps", status: "Emailed", added: "2026-07-20"),
            .init(company: "Sorrelwick Solar Co", industry: "Residential Solar", location: "Phoenix, AZ", source: "Sales Navigator", status: "Replied", added: "2026-07-20"),
            .init(company: "Quorrel Biolabs", industry: "Biotech", location: "Basel, CH", source: "Apollo", status: "Enriched", added: "2026-07-19"),
            .init(company: "Crestline EV Motors", industry: "EV Dealers", location: "Orlando, FL", source: "Sales Navigator", status: "Personalized", added: "2026-07-19"),
            .init(company: "Kestrelbrook Credit Union", industry: "Credit Unions", location: "Sacramento, CA", source: "Apollo", status: "Emailed", added: "2026-07-18"),
            .init(company: "Brightmoor Web Studio", industry: "Web Agencies", location: "Austin, TX", source: "Job Signals", status: "Scraped", added: "2026-07-18"),
            .init(company: "Fernhollow Assisted Living", industry: "Assisted Living", location: "Naples, FL", source: "Google Maps", status: "Emailed", added: "2026-07-17"),
            .init(company: "Zephyrine Home Energy", industry: "Residential Solar", location: "Tucson, AZ", source: "Google Maps", status: "Emailed", added: "2026-07-17"),
            .init(company: "Halvorine Therapeutics", industry: "Biotech", location: "Munich, DE", source: "Apollo", status: "Enriched", added: "2026-07-16"),
            .init(company: "Wrenfield EV Gallery", industry: "EV Dealers", location: "San Jose, CA", source: "Sales Navigator", status: "Emailed", added: "2026-07-16"),
            .init(company: "Thornmere Federal CU", industry: "Credit Unions", location: "Fresno, CA", source: "Apollo", status: "Personalized", added: "2026-07-15"),
            .init(company: "Larkspire & Vine Design", industry: "Web Agencies", location: "Dallas, TX", source: "Job Signals", status: "Emailed", added: "2026-07-15"),
            .init(company: "Hazelquist Care", industry: "Assisted Living", location: "Sarasota, FL", source: "Google Maps", status: "Replied", added: "2026-07-14"),
            .init(company: "Glimmerhaw Solar Partners", industry: "Residential Solar", location: "Mesa, AZ", source: "Sales Navigator", status: "Emailed", added: "2026-07-14"),
            .init(company: "Cobalt Bio Systems", industry: "Biotech", location: "Copenhagen, DK", source: "Apollo", status: "Scraped", added: "2026-07-13"),
            .init(company: "Corvane Electric Autos", industry: "EV Dealers", location: "Las Vegas, NV", source: "Sales Navigator", status: "Emailed", added: "2026-07-13"),
            .init(company: "Brindleback CU", industry: "Credit Unions", location: "San Diego, CA", source: "Apollo", status: "Emailed", added: "2026-07-12"),
            .init(company: "Inkwhistle Studios", industry: "Web Agencies", location: "Houston, TX", source: "Job Signals", status: "Enriched", added: "2026-07-12"),
            .init(company: "Bramblewick Living", industry: "Assisted Living", location: "Clearwater, FL", source: "Google Maps", status: "Emailed", added: "2026-07-11"),
            .init(company: "Cobblequartz Solar", industry: "Residential Solar", location: "Scottsdale, AZ", source: "Google Maps", status: "Bounced", added: "2026-07-11"),
            .init(company: "Tidemarrow Biometrics", industry: "Biotech", location: "Amsterdam, NL", source: "Apollo", status: "Emailed", added: "2026-07-10"),
            .init(company: "Velocity EV Outlet", industry: "EV Dealers", location: "Reno, NV", source: "Sales Navigator", status: "Scraped", added: "2026-07-10"),
            .init(company: "Thistlecombe CU", industry: "Credit Unions", location: "Bakersfield, CA", source: "Apollo", status: "Emailed", added: "2026-07-09"),
            .init(company: "Glintmoor Web Co", industry: "Web Agencies", location: "San Antonio, TX", source: "Job Signals", status: "Personalized", added: "2026-07-09"),
        ],
        byRegion: [
            .init(label: "Florida", count: 341),
            .init(label: "California", count: 296),
            .init(label: "Texas", count: 214),
            .init(label: "Arizona", count: 188),
            .init(label: "United Kingdom", count: 96),
            .init(label: "Unknown", count: 105),
        ],
        facets: FilterFacets(
            lanes: [(.deep, 96), (.standard, 765), (LeadFilter.Lane.none, 379)],
            regions: [.init(value: "Florida", count: 341), .init(value: "California", count: 296),
                      .init(value: "Texas", count: 214), .init(value: "Arizona", count: 188),
                      .init(value: "United Kingdom", count: 96), .init(value: "Unknown", count: 105)],
            sources: [.init(value: "Sales Navigator", count: 512), .init(value: "Google Maps", count: 388),
                      .init(value: "Apollo", count: 204), .init(value: "Job Signals", count: 136)],
            industries: [.init(value: "Assisted Living", count: 296), .init(value: "Residential Solar", count: 248),
                         .init(value: "EV Dealers", count: 187), .init(value: "Biotech", count: 183),
                         .init(value: "Credit Unions", count: 174), .init(value: "Web Agencies", count: 152)]),
        matchingCount: 1240
    )

    /// Frozen "filter applied" variant for the preview harness — the same fixture
    /// narrowed to one lane + one region, so a still can show the filter bar in its
    /// active state and the hero numbers moving with it (bible §9).
    static let abFiltered: ABLeadsData = {
        var d = ABLeadsData(
            totals: .init(scraped: 296, emailed: 214, replies: 31),
            emailedOfScrapedPct: 72.3,
            repliesOfEmailedPct: 14.5,
            leadsAddedWeekly: .init(weeks: ab.leadsAddedWeekly.weeks,
                                    values: [8, 11, 14, 12, 17, 21, 15, 18, 24, 27, 21, 25]),
            leadsMessagedWeekly: .init(weeks: ab.leadsMessagedWeekly.weeks,
                                       values: [5, 7, 9, 8, 13, 14, 11, 13, 18, 20, 16, 19]),
            bySource: [.init(label: "Sales Navigator", count: 171), .init(label: "Google Maps", count: 125)],
            byIndustry: [.init(label: "Residential Solar", count: 141), .init(label: "Assisted Living", count: 96),
                         .init(label: "Credit Unions", count: 59)],
            byStatus: [.init(label: "Campaigned", count: 214), .init(label: "Personalized", count: 46),
                       .init(label: "Scraped", count: 36)],
            recentLeads: Array(ab.recentLeads.filter { $0.location.hasSuffix("CA") }),
            byRegion: [.init(label: "California", count: 296)],
            filter: LeadFilter(lane: .standard, region: "California"),
            facets: ab.facets,
            matchingCount: 296)
        d.emailedDenominator = 296
        return d
    }()
}

// Status -> role color mapping (two-accent discipline; decision-log #5).
enum ABStatusRole {
    case reward      // Replied -> pink
    case active      // Emailed -> teal
    case warn        // Bounced / Do not contact -> warm neutral
    case neutral     // Scraped / Enriched / Personalized

    init(_ status: String) {
        switch status.lowercased() {
        case "replied":                       self = .reward
        // "campaigned" is the live pipeline's outreach stage (= emailed).
        case "emailed", "campaigned":         self = .active
        case "bounced", "do not contact":     self = .warn
        default:                              self = .neutral
        }
    }
}

// MARK: - Live mapping (Supabase pipeline → the frozen ABLeads shape)

extension ABLeadsData {
    /// Build the Leads-tab view model from the live dashboard pipeline
    /// (`LeadsRepository.fetch()` → `DashboardInputs`). PURE and TOTAL: no I/O, no
    /// force-unwraps; every divisor is guarded and empty/degraded inputs are
    /// tolerated (all-zero series, nil fields, failed supplementary reads).
    ///
    /// Mapping decisions (documented in SHIP-NOTES.md):
    /// - EVERY figure is computed from the leads passing `filter`. There is no
    ///   path that pairs a filtered list with unfiltered headline stats — that was
    ///   the whole point of the filter bar, and a mixed view is a lie the user
    ///   cannot see.
    /// - `scraped`  = leads matching the filter. Exact while the snapshot is the
    ///   whole table (`leadsComplete`); otherwise the unfiltered view keeps using
    ///   the exact full-table figures and the filtered view discloses "N of M".
    /// - `emailed`  = matching leads at the `campaigned` enrichment stage (added to
    ///   an outbound campaign).
    /// - `replies`  = matching leads that appear in `replies` — the same lead grain
    ///   as `emailed`, so the reply rate can't exceed 100% on multi-reply threads.
    /// - weekly series share ONE 12-week window anchored to `now` (aligned axes):
    ///   added counts distinct matching leads by `created_at`; messaged counts
    ///   DISTINCT matching leads per week by `send_queue.sent_at`. Both fail-open to
    ///   a zero-filled series.
    /// - breakdowns + facet menus count over the same matching set.
    ///
    /// `now` is injectable for deterministic tests; production passes the wall clock.
    init(inputs: DashboardInputs, filter: LeadFilter = .all, now: Date = Date()) {
        let facets = inputs.leads.map {
            LeadFacets(lead: $0,
                       deepLane: inputs.deepLaneLeadIDs.contains($0.id),
                       personalized: inputs.personalizedLeadIDs.contains($0.id))
        }
        // A lane filter over degraded lane reads would silently answer "everything
        // is unpersonalized". Drop that dimension rather than answer wrongly.
        let effective = inputs.lanesDegraded ? LeadFilter(lane: nil, region: filter.region,
                                                          source: filter.source,
                                                          industry: filter.industry) : filter
        let matchingIndices = facets.indices.filter { effective.matches(facets[$0]) }
        let matching = matchingIndices.map { inputs.leads[$0] }
        let matchingFacets = matchingIndices.map { facets[$0] }
        let matchingIDs = Set(matching.map(\.id))

        // Which arithmetic the headline figures use:
        // - complete snapshot → count the matching rows (exact, and it moves with
        //   the filter);
        // - windowed snapshot, nothing filtered → keep the exact full-table figures
        //   the HEAD reads give us, rather than downgrading a working number;
        // - windowed snapshot + a filter → the window is all we have; count it and
        //   say so ("N of M").
        let windowed = !inputs.leadsComplete
        let useGlobals = windowed && !effective.isActive

        let scraped = useGlobals ? inputs.totalCount : matching.count
        let emailed = useGlobals
            ? (inputs.statusCounts["campaigned"] ?? ABLeadsData.campaignedCount(matching))
            : ABLeadsData.campaignedCount(matching)
        let replies = useGlobals
            ? inputs.repliedLeadIDs.count
            : inputs.repliedLeadIDs.intersection(matchingIDs).count
        // Denominator matches the numerator's grain: full table when both are
        // full-table figures, the matching set otherwise.
        let ratioDenominator = useGlobals
            ? (inputs.statusCounts.isEmpty ? inputs.leads.count : inputs.totalCount)
            : matching.count

        self.filter = effective
        self.laneFilterAvailable = !inputs.lanesDegraded
        self.partial = inputs.partial
        self.matchingCount = matching.count
        self.totals = Totals(scraped: scraped, emailed: emailed, replies: replies)
        self.emailedDenominator = ratioDenominator
        self.emailedOfScrapedPct = ABLeadsData.percent(emailed, of: ratioDenominator)
        self.repliesOfEmailedPct = ABLeadsData.percent(replies, of: emailed)

        self.leadsAddedWeekly = ABLeadsData.weeklySeries(
            timestamps: matching.compactMap { $0.createdAt }, weeks: 12, now: now)
        // Sends belonging to leads outside the current lens are not this view's
        // trend — except in the globals case, where the snapshot is a window and
        // intersecting it would under-count sends to leads we simply didn't fetch.
        let sends = useGlobals ? inputs.messagedSends
                               : inputs.messagedSends.filter { matchingIDs.contains($0.leadID) }
        self.leadsMessagedWeekly = ABLeadsData.weeklySeries(events: sends, weeks: 12, now: now)

        self.bySource = ABLeadsData.breakdown(matchingFacets, topN: 6) { $0.source }
        self.byIndustry = ABLeadsData.breakdown(matchingFacets, topN: 6) { $0.industry }
        self.byRegion = ABLeadsData.breakdown(matchingFacets, topN: 6) { $0.region }
        self.byStatus = ABLeadsData.statusBreakdown(matching)
        self.facets = FilterFacets.build(facets, filter: effective)
        // Disclose whenever the numbers come from a window rather than the book.
        self.breakdownScopeNote = windowed
            ? "\(inputs.leads.count) of \(inputs.totalCount)" : nil

        self.recentLeads = matching.prefix(ABLeadsData.listCap).map(ABLeadsData.lead)
    }

    /// One DB row → one list row. Shared by the tab's list and the search results,
    /// so a hit renders exactly like the lead it is.
    static func lead(_ row: LeadRow) -> Lead {
        Lead(leadID: row.id,
             company: row.companyName?.nilIfEmpty ?? "Unknown",
             industry: row.industry?.nilIfEmpty ?? "—",
             location: locationLabel(city: row.city, state: row.state, location: row.location),
             source: row.leadSource?.nilIfEmpty ?? "—",
             status: stageLabel(row.enrichmentStage),
             added: dayLabel(row.createdAt),
             firstName: row.firstName?.nilIfEmpty)
    }

    /// Leads that reached the outreach stage. One spelling of the comparison, used
    /// by both the exact and windowed paths.
    static func campaignedCount(_ leads: [LeadRow]) -> Int {
        leads.filter { ($0.enrichmentStage ?? "").lowercased() == "campaigned" }.count
    }

    /// `n/d` as a percentage, guarded: a zero (or negative) denominator yields 0,
    /// never NaN/inf. The single choke-point for both KPI ratios.
    static func percent(_ n: Int, of d: Int) -> Double {
        d > 0 ? (Double(n) / Double(d)) * 100.0 : 0
    }

    /// Row label for where a lead is. Prefers the structured city/state pair; falls
    /// back to the free-text `location` the Sales Navigator path writes instead
    /// (without it, ~3 of every 4 rows showed an em dash).
    static func locationLabel(city: String?, state: String?, location: String? = nil) -> String {
        let parts = [city, state].compactMap { $0?.nilIfEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return location?.nilIfEmpty ?? "—"
    }

    /// Locale-stable display casing for a stage token; nil/empty → "Unknown".
    static func stageLabel(_ stage: String?) -> String {
        guard let s = stage?.nilIfEmpty else { return "Unknown" }
        return s.capitalized(with: Locale(identifier: "en_US_POSIX"))
    }

    /// `created_at` timestamp → a stable "yyyy-MM-dd" day label (matching the
    /// fixture's `added` format); unparseable/nil → "—".
    static func dayLabel(_ iso: String?) -> String {
        guard let date = DateParse.iso(iso) else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Count one already-derived facet dimension, largest first (ties broken by
    /// label for determinism), capped at `topN` with the tail folded into a neutral
    /// "Other". Counting FACETS rather than raw columns is what keeps a panel and
    /// its filter menu telling the same story — both read the same derivation.
    static func breakdown(
        _ facets: [LeadFacets], topN: Int, value: (LeadFacets) -> String
    ) -> [Breakdown] {
        var counts: [String: Int] = [:]
        for facet in facets { counts[value(facet), default: 0] += 1 }
        return topBreakdowns(counts, topN: topN)
    }

    /// Pipeline-stage rollup over the leads currently shown. Counted from the
    /// snapshot (not the exact per-stage HEAD reads) precisely so it MOVES with the
    /// filter — a "By status" panel frozen at full-table totals beside a filtered
    /// list is the mixed view this tab is designed not to produce.
    static func statusBreakdown(_ leads: [LeadRow]) -> [Breakdown] {
        var counts: [String: Int] = [:]
        for lead in leads { counts[stageLabel(lead.enrichmentStage), default: 0] += 1 }
        return topBreakdowns(counts, topN: 8)
    }

    private static func topBreakdowns(_ counts: [String: Int], topN: Int) -> [Breakdown] {
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var out = sorted.prefix(topN).map { Breakdown(label: $0.key, count: $0.value) }
        if sorted.count > topN {
            let other = sorted.dropFirst(topN).reduce(0) { $0 + $1.value }
            if other > 0 {
                // Merge into an existing "Other" (a real category literally named
                // "Other") rather than appending a duplicate — Breakdown.id is the
                // label, so a duplicate would collide in ForEach identity.
                if let i = out.firstIndex(where: { $0.label == "Other" }) {
                    out[i] = Breakdown(label: "Other", count: out[i].count + other)
                } else {
                    out.append(Breakdown(label: "Other", count: other))
                }
            }
        }
        return out
    }

    /// Distinct leads (each `created_at` is one lead) bucketed into a `weeks`-long
    /// window anchored to `now`.
    static func weeklySeries(timestamps: [String], weeks: Int, now: Date = Date()) -> Series {
        weekBuckets(timestamps.compactMap { DateParse.iso($0).map { ($0, String?.none) } },
                    weeks: weeks, now: now)
    }

    /// Distinct LEADS messaged per week (dedup by `lead_id` within a week) over the
    /// same `now`-anchored window — so a lead messaged twice in a week counts once
    /// and the two trend charts share an identical x-axis.
    static func weeklySeries(events: [DashboardInputs.SentEvent], weeks: Int, now: Date = Date()) -> Series {
        weekBuckets(events.compactMap { e in DateParse.iso(e.sentAt).map { ($0, Optional(e.leadID)) } },
                    weeks: weeks, now: now)
    }

    /// Core weekly bucketer. Produces EXACTLY `weeks` consecutive ISO-week buckets
    /// (UTC) ending at the week containing `now`, zero-filled — so the x-axis is
    /// fixed and clock-anchored, out-of-window timestamps (stray/outlier dates) are
    /// simply ignored rather than shifting the visible window, and two series over
    /// the same `now` align bucket-for-bucket. Items with a non-nil dedup key count
    /// once per (week, key).
    private static func weekBuckets(_ items: [(date: Date, key: String?)],
                                    weeks: Int, now: Date) -> Series {
        let n = max(1, weeks)
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone

        let nowComps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        guard let thisWeek = cal.date(from: nowComps) else { return Series(weeks: [], values: []) }

        var weekStarts: [Date] = []
        for i in stride(from: n - 1, through: 0, by: -1) {   // oldest → newest
            if let d = cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek) { weekStarts.append(d) }
        }
        let index = Dictionary(weekStarts.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var values = [Int](repeating: 0, count: weekStarts.count)
        var seen = Set<String>()   // "<weekIdx>|<key>" for distinct-per-week dedup

        for item in items {
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: item.date)
            guard let ws = cal.date(from: comps), let idx = index[ws] else { continue }  // outside window
            if let key = item.key {
                let token = "\(idx)|\(key)"
                if seen.contains(token) { continue }
                seen.insert(token)
            }
            values[idx] += 1
        }

        let label = DateFormatter()
        label.locale = Locale(identifier: "en_US_POSIX")
        label.dateFormat = "MMM d"
        label.timeZone = cal.timeZone
        return Series(weeks: weekStarts.map { label.string(from: $0) }, values: values)
    }
}
