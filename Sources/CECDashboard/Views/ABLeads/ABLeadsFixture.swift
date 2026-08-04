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
    /// "N of M" when the source/industry breakdowns are computed over a fetched
    /// window smaller than the true total — surfaced so a windowed slice is never
    /// presented as a full-table total. nil (no note) in the fixture / when complete.
    var breakdownScopeNote: String? = nil

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
        ]
    )
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
    /// Mapping decisions (documented in builds/lead-dashboard/SHIP-NOTES.md):
    /// - `scraped`  = exact full-table lead count (`totalCount`).
    /// - `emailed`  = distinct leads that reached the `campaigned` enrichment stage
    ///   (added to an outbound campaign). Exact when the full-table stage counts are
    ///   present; else a windowed fallback from the fetched leads — and then the
    ///   ratio denominator narrows to the same window so it stays leads/leads.
    /// - `replies`  = distinct replied leads (`inputs.replyCount`, fail-open to 0),
    ///   the same grain as `emailed`, so the reply rate can't exceed 100% on
    ///   multi-reply threads.
    /// - weekly series share ONE 12-week window anchored to `now` (aligned axes):
    ///   added counts distinct leads by `created_at`; messaged counts DISTINCT leads
    ///   per week by `send_queue.sent_at`. Both fail-open to a zero-filled series.
    /// - breakdowns come from the fetched leads window (with a "N of M" scope note
    ///   when windowed) / exact stage counts.
    ///
    /// `now` is injectable for deterministic tests; production passes the wall clock.
    init(inputs: DashboardInputs, now: Date = Date()) {
        let scraped = inputs.totalCount
        // Exact per-lead campaigned count when the full-table stage read succeeded;
        // else a windowed fallback (and the ratio denominator narrows to match).
        let usedWindowedEmailed = inputs.statusCounts.isEmpty
        let emailed: Int = usedWindowedEmailed
            ? inputs.leads.filter { ($0.enrichmentStage ?? "").lowercased() == "campaigned" }.count
            : (inputs.statusCounts["campaigned"] ?? 0)
        let ratioDenominator = usedWindowedEmailed ? inputs.leads.count : scraped
        let replies = max(0, inputs.replyCount)

        self.totals = Totals(scraped: scraped, emailed: emailed, replies: replies)
        self.emailedDenominator = ratioDenominator
        self.emailedOfScrapedPct = ABLeadsData.percent(emailed, of: ratioDenominator)
        self.repliesOfEmailedPct = ABLeadsData.percent(replies, of: emailed)

        self.leadsAddedWeekly = ABLeadsData.weeklySeries(
            timestamps: inputs.leads.compactMap { $0.createdAt }, weeks: 12, now: now)
        self.leadsMessagedWeekly = ABLeadsData.weeklySeries(
            events: inputs.messagedSends, weeks: 12, now: now)

        self.bySource = ABLeadsData.breakdown(inputs.leads, topN: 6) { $0.leadSource }
        self.byIndustry = ABLeadsData.breakdown(inputs.leads, topN: 6) { $0.industry }
        self.byStatus = ABLeadsData.statusBreakdown(inputs)
        // Source/industry are windowed over the fetched leads; disclose it when the
        // window is smaller than the true total (byStatus uses exact counts — no note).
        self.breakdownScopeNote = inputs.totalCount > inputs.leads.count
            ? "\(inputs.leads.count) of \(inputs.totalCount)" : nil

        self.recentLeads = inputs.leads.prefix(50).map { row in
            Lead(leadID: row.id,
                 company: row.companyName?.nilIfEmpty ?? "Unknown",
                 industry: row.industry?.nilIfEmpty ?? "—",
                 location: ABLeadsData.locationLabel(city: row.city, state: row.state),
                 source: row.leadSource?.nilIfEmpty ?? "—",
                 status: ABLeadsData.stageLabel(row.enrichmentStage),
                 added: ABLeadsData.dayLabel(row.createdAt),
                 firstName: row.firstName?.nilIfEmpty)
        }
    }

    /// `n/d` as a percentage, guarded: a zero (or negative) denominator yields 0,
    /// never NaN/inf. The single choke-point for both KPI ratios.
    static func percent(_ n: Int, of d: Int) -> Double {
        d > 0 ? (Double(n) / Double(d)) * 100.0 : 0
    }

    private static func locationLabel(city: String?, state: String?) -> String {
        let parts = [city, state].compactMap { $0?.nilIfEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    /// Locale-stable display casing for a stage token; nil/empty → "Unknown".
    static func stageLabel(_ stage: String?) -> String {
        guard let s = stage?.nilIfEmpty else { return "Unknown" }
        return s.capitalized(with: Locale(identifier: "en_US_POSIX"))
    }

    /// `created_at` timestamp → a stable "yyyy-MM-dd" day label (matching the
    /// fixture's `added` format); unparseable/nil → "—".
    private static func dayLabel(_ iso: String?) -> String {
        guard let date = DateParse.iso(iso) else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Count a categorical lead field (nil/empty → "Unknown"), largest first
    /// (ties broken by label for determinism), capped at `topN` with the tail
    /// folded into a neutral "Other".
    private static func breakdown(
        _ leads: [LeadRow], topN: Int, value: (LeadRow) -> String?
    ) -> [Breakdown] {
        var counts: [String: Int] = [:]
        for lead in leads {
            let key = value(lead)?.nilIfEmpty ?? "Unknown"
            counts[key, default: 0] += 1
        }
        return topBreakdowns(counts, topN: topN)
    }

    /// Status breakdown from the EXACT full-table stage counts when present
    /// (a recency window skews a pipeline-stage distribution toward "scraped");
    /// else a windowed rollup from the fetched leads.
    private static func statusBreakdown(_ inputs: DashboardInputs) -> [Breakdown] {
        if !inputs.statusCounts.isEmpty {
            // uniquingKeysWith (not uniqueKeysWithValues) — two stage tokens that
            // ever collapse to the same display label must MERGE, never trap.
            let labeled = Dictionary(inputs.statusCounts.map { (stageLabel($0.key), $0.value) },
                                     uniquingKeysWith: +)
            return topBreakdowns(labeled, topN: 8)
        }
        return breakdown(inputs.leads, topN: 8) { $0.enrichmentStage }
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
