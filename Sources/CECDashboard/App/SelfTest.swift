import AppKit
import Foundation

/// Headless verification of the decode contract (run with `--selftest`).
/// Exercises the decode contract plus every pure builder/compose seam.
/// Main-actor: `--selftest` runs pre-boot from `App.init()` on the main thread,
/// and the copy checks touch AppKit (`NSPasteboard`).
@MainActor
enum SelfTest {
    static func run() -> Never {
        var problems: [String] = []

        // The compose/parse sample rows (v_cec_leads shape — 7.2 remap; the old
        // widget-grid/DashboardBuilder/Packer suite left with the Pipeline tab).
        let sampleLeads: [LeadRow] = [
            LeadRow(id: "1", companyName: "Acme", firstName: "A", industry: "Auto",
                    leadSource: "gmaps-leads", city: "Tampa", state: "FL",
                    createdAt: "2026-06-10T12:00:00+00:00",
                    personalized: true, hasResearch: true),
            LeadRow(id: "2", companyName: "Globex", firstName: "B", industry: "Biotech",
                    leadSource: "sales-nav", city: "Austin", state: "TX",
                    createdAt: "2026-06-12T12:00:00.500+00:00"),
            LeadRow(id: "3", companyName: "Initech", firstName: "C", industry: "Tech",
                    leadSource: "gmaps-leads", city: nil, state: nil, createdAt: nil),
        ]

        // ── Leads tab: LeadsRepository.compose (P1 renovation seam) ────────────────
        problems.append(contentsOf: leadsComposeChecks(sampleLeads: sampleLeads))

        // LeadAnswers: the shared phrasing the Siri App Intent and the --query CLI BOTH
        // route through. These assert the contract so the two voice surfaces can't drift.
        if LeadAnswers.count(1102) != "You have 1102 leads." {
            problems.append("answers: count phrasing changed")
        }
        if LeadAnswers.breakdown([:], singular: "source", plural: "sources") != "No source data yet." {
            problems.append("answers: empty breakdown should use the singular noun")
        }
        // Top-3, count desc then key asc; the 4th group ('d') is dropped.
        let bd = LeadAnswers.breakdown(["b": 5, "a": 5, "c": 9, "d": 1], singular: "tier", plural: "tiers")
        if bd != "Top tiers: c with 9, a with 5, b with 5." {
            problems.append("answers: breakdown top-3/tiebreak changed (got \(bd))")
        }
        // The recency-sample qualifier appears only when sampled.
        if !LeadAnswers.breakdown(["a": 1], singular: "source", plural: "sources", sampled: true)
            .contains("among the \(LeadAnswers.breakdownWindow) most recent leads") {
            problems.append("answers: sampled qualifier missing")
        }

        // ── Lead profile: ProfileRepository.compose (P3) ────────────────────────────
        problems.append(contentsOf: profileComposeChecks())

        // ── Pinned leads: PinsStore (P5) ────────────────────────────────────────────
        problems.append(contentsOf: pinsChecks())

        // ── Demo book (#113): fictional, complete enough, partial enough ────────────
        problems.append(contentsOf: demoBookChecks())

        // ⌘W lifecycle pin (review 2026-08-16): SwiftUI terminates a
        // closed-scene app unless the adaptor answers false here — flipping
        // this back to true is exactly the "closes and never comes back"
        // report, and the only other thing holding it is a comment.
        if CECAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) {
            problems.append("lifecycle: applicationShouldTerminateAfterLastWindowClosed must be "
                + "false — the app dies on ⌘W and the Dock has nothing to reopen")
        }

        // (Backlog/Campaigns/Pipeline check families left with their tabs — 7.2.)

        // ── Leads tab: live DashboardInputs → ABLeadsData mapping (pure/total) ──────
        problems.append(contentsOf: abLeadsMappingChecks())

        let summary = "leads-surface remap (v_cec_* views)"
        if problems.isEmpty {
            print("SELFTEST PASS — \(summary)")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("SELFTEST FAIL — \(summary)\n  - \(problems.joined(separator: "\n  - "))\n".utf8))
            exit(1)
        }
    }

    /// Fixed clock so every now-anchored 12-week window below is deterministic.
    private static let abNow = DateParse.iso("2026-07-24T12:00:00+00:00") ?? Date()

    /// The two-lead sample the mapping checks share. "a" carries campaign-ready
    /// copy and a dossier (view booleans); "b" is a bare scrape.
    private static var abSampleLeads: [LeadRow] {
        [
            LeadRow(id: "a", companyName: "Acme", firstName: "Ada", industry: "Auto",
                    leadSource: "sales-nav", city: "Tampa", state: "FL",
                    createdAt: "2026-07-01T12:00:00+00:00",
                    personalized: true, hasResearch: true),
            LeadRow(id: "b", companyName: nil, firstName: nil, industry: nil,
                    leadSource: nil, city: nil, state: nil,
                    createdAt: "2026-07-08T12:00:00+00:00"),
        ]
    }

    /// Exercises the live→ABLeads mapping (`ABLeadsData(inputs:filter:)`): funnel
    /// math is guarded (no NaN on zero denominators), the reskin carries the DB id
    /// needed to open a profile, nil lead fields are tolerated, weekly series bucket
    /// correctly, and empty/degraded inputs never crash. Pins the divisor-guard bug
    /// class.
    private static func abLeadsMappingChecks() -> [String] {
        var problems: [String] = []

        let now = abNow
        let leads = abSampleLeads
        // Lead "a" messaged TWICE in one week + lead "b" once → distinct-per-week = 2.
        let sends = [
            DashboardInputs.SentEvent(leadID: "a", sentAt: "2026-07-14T09:00:00+00:00"),
            DashboardInputs.SentEvent(leadID: "a", sentAt: "2026-07-15T09:00:00+00:00"),
            DashboardInputs.SentEvent(leadID: "b", sentAt: "2026-07-15T09:00:00+00:00"),
        ]
        // A COMPLETE snapshot: the fetched leads ARE the table, so every figure is
        // counted off them (and therefore moves with the filter).
        let inputs = DashboardInputs(
            leads: leads, totalCount: 2, leadsComplete: true,
            repliedLeadIDs: ["a", "ghost"],
            messagedSends: sends)
        let d = ABLeadsData(inputs: inputs, now: now)

        if d.totals.scraped != 2 { problems.append("abmap: scraped must count the matching leads (got \(d.totals.scraped))") }
        // Emailed = DISTINCT leads in the sent-event log (both a and b were sent to).
        if d.totals.emailed != 2 { problems.append("abmap: emailed must count leads with a send on record (got \(d.totals.emailed))") }
        // "ghost" replied but is not in the lead book — the ratio is replied LEADS
        // over emailed LEADS, so a reply with no matching lead cannot inflate it.
        if d.totals.replies != 1 {
            problems.append("abmap: replies must intersect the shown leads, not count reply rows (got \(d.totals.replies))")
        }
        if abs(d.emailedOfScrapedPct - 100.0) > 0.001 { problems.append("abmap: emailedOfScrapedPct math (got \(d.emailedOfScrapedPct))") }
        if abs(d.repliesOfEmailedPct - 50.0) > 0.001 { problems.append("abmap: repliesOfEmailedPct math (got \(d.repliesOfEmailedPct))") }
        if d.recentLeads.first?.leadID != "a" { problems.append("abmap: recent lead must carry the DB id for profile-open") }
        if d.recentLeads.count != 2 { problems.append("abmap: recentLeads count (got \(d.recentLeads.count))") }
        if d.recentLeads.last?.company != "Unknown" { problems.append("abmap: nil company_name must render as Unknown") }
        if d.recentLeads.first?.location != "Tampa, FL" { problems.append("abmap: location must join city/state") }
        if d.recentLeads.last?.location != "—" { problems.append("abmap: nil city/state/location must render as em dash") }
        if d.leadsAddedWeekly.values.reduce(0, +) != 2 { problems.append("abmap: added-weekly must total the leads") }
        // F3: distinct leads per week — lead "a" messaged twice in one week counts once.
        if d.leadsMessagedWeekly.values.reduce(0, +) != 2 {
            problems.append("abmap: messaged-weekly must count DISTINCT leads/week (got \(d.leadsMessagedWeekly.values.reduce(0, +)))")
        }
        // F4: both trends share one now-anchored 12-week axis (identical week labels).
        if d.leadsAddedWeekly.weeks.count != 12 || d.leadsMessagedWeekly.weeks.count != 12 {
            problems.append("abmap: trends must be exactly 12 buckets (got \(d.leadsAddedWeekly.weeks.count)/\(d.leadsMessagedWeekly.weeks.count))")
        }
        if d.leadsAddedWeekly.weeks != d.leadsMessagedWeekly.weeks {
            problems.append("abmap: added/messaged trends must share an identical x-axis")
        }
        if d.leadsAddedWeekly.weeks.count != d.leadsAddedWeekly.values.count { problems.append("abmap: added-weekly weeks/values length mismatch") }
        // A complete snapshot presents no window, so it carries no scope note.
        if d.breakdownScopeNote != nil { problems.append("abmap: a complete snapshot must not claim a window (got \(d.breakdownScopeNote ?? "nil"))") }
        // The status panel is a FUNNEL in stage order, counted off the snapshot so
        // it moves with the filter: Scraped=all, Researched/Personalized=the view
        // booleans, Campaigned=the sent-event set.
        if d.byStatus.map(\.label) != ["Scraped", "Researched", "Personalized", "Campaigned"] {
            problems.append("abmap: byStatus must be the stage funnel in order (got \(d.byStatus.map(\.label)))")
        }
        if d.byStatus.map(\.count) != [2, 1, 1, 2] {
            problems.append("abmap: funnel counts must derive from the view booleans + sent set (got \(d.byStatus.map(\.count)))")
        }
        // Funnel rows carry their retention SHARE of the Scraped denominator —
        // the overlap cue (design review): 2/2, 1/2, 1/2, 2/2.
        if d.byStatus.compactMap(\.share).map({ Int($0.rounded()) }) != [100, 50, 50, 100] {
            problems.append("abmap: funnel shares must be percent-of-scraped (got \(d.byStatus.map(\.share)))")
        }
        // ROW-LABEL derivation (LeadFacets.stage) — pinned DIRECTLY, not via the
        // funnel: the two are separate implementations, and deleting the
        // emailed branch left the suite green while every row mislabelled
        // (code review). Lead "a" replied → the reward outcome outranks
        // Campaigned; lead "b" was sent to but never replied.
        if d.recentLeads.first(where: { $0.leadID == "a" })?.status != "Replied" {
            problems.append("abmap: a replied lead's row must read Replied (got "
                + "\(d.recentLeads.first(where: { $0.leadID == "a" })?.status ?? "nil"))")
        }
        if d.recentLeads.first(where: { $0.leadID == "b" })?.status != "Campaigned" {
            problems.append("abmap: an emailed lead's row must read Campaigned (got "
                + "\(d.recentLeads.first(where: { $0.leadID == "b" })?.status ?? "nil"))")
        }
        // The full ladder, one rung at a time (kills single-branch deletions).
        let ladder = LeadRow(id: "l", companyName: nil, firstName: nil, industry: nil,
                             leadSource: nil, city: nil, state: nil, createdAt: nil,
                             personalized: true, hasResearch: true)
        if LeadFacets.stage(lead: ladder, emailed: false) != "Personalized"
            || LeadFacets.stage(lead: ladder, emailed: true) != "Campaigned"
            || LeadFacets.stage(lead: ladder, emailed: true, replied: true) != "Replied" {
            problems.append("abmap: the furthest-stage ladder broke")
        }
        var research = ladder; research.personalized = false
        if LeadFacets.stage(lead: research, emailed: false) != "Researched" {
            problems.append("abmap: hasResearch alone must read Researched")
        }
        research.hasResearch = false
        if LeadFacets.stage(lead: research, emailed: false) != "Scraped" {
            problems.append("abmap: a bare row must read Scraped")
        }
        // DEGRADED sent-events: the emailed test falls back to the outreach
        // axis (built through compose, so the degradation flags are the real
        // ones) — an empty event set is a FAILURE, and deriving stages from it
        // relabelled every campaigned lead "Personalized" (swift-semantics).
        var axisLead = ladder; axisLead.outreach = "sequence_done"
        let degradedSnap = LeadSnapshot(LeadsRepository.compose(
            leads: [axisLead], totalCount: 1, leadsComplete: true,
            messaged: ([], ok: false)))
        if degradedSnap.facets.first?.stage != "Campaigned" {
            problems.append("abmap: under a failed sent-events read the stage must fall "
                + "back to the outreach axis (got \(degradedSnap.facets.first?.stage ?? "nil"))")
        }
        // …and a CLEAN empty event log must NOT consult the axis: an unemailed
        // book really is unemailed (the fallback fires only on failure).
        let cleanSnap = LeadSnapshot(LeadsRepository.compose(
            leads: [axisLead], totalCount: 1, leadsComplete: true,
            messaged: ([], ok: true)))
        if cleanSnap.facets.first?.stage != "Personalized" {
            problems.append("abmap: a clean empty event log must not fall back to the axis "
                + "(got \(cleanSnap.facets.first?.stage ?? "nil"))")
        }
        // BOTH fallback layers, pinned against the artifact only IT produces
        // (delta round 1: the ABLeadsData half was deletable under a green
        // suite — on a failed sent-events read the emailed KPI, the funnel's
        // Campaigned row and the reply count would collapse to 0 while the
        // row labels correctly read Campaigned, an on-screen contradiction).
        let degradedData = ABLeadsData(inputs: LeadsRepository.compose(
            leads: [axisLead], totalCount: 1, leadsComplete: true,
            replied: (["l"], ok: true), messaged: ([], ok: false)), now: now)
        if degradedData.totals.emailed != 1 {
            problems.append("abmap: the emailed KPI must fall back to the axis under a "
                + "failed sent-events read (got \(degradedData.totals.emailed))")
        }
        if degradedData.byStatus.last?.count != 1 {
            problems.append("abmap: the funnel's Campaigned row must fall back to the axis "
                + "(got \(degradedData.byStatus.last?.count ?? -1))")
        }
        if degradedData.totals.replies != 1 {
            problems.append("abmap: the reply count must intersect the FALLBACK emailed set "
                + "(got \(degradedData.totals.replies))")
        }
        // status_row_missing rows are COUNTED into the disclosure.
        var orphan = ladder; orphan.statusRowMissing = true
        let orphanData = ABLeadsData(inputs: DashboardInputs(
            leads: [orphan], totalCount: 1, leadsComplete: true), now: now)
        if orphanData.statusRowsMissing != 1 {
            problems.append("abmap: statusRowMissing rows must surface in the count "
                + "(got \(orphanData.statusRowsMissing))")
        }
        // F4: an out-of-window outlier timestamp must not shift/blank the axis.
        let outlier = ABLeadsData(inputs: DashboardInputs(
            leads: [LeadRow(id: "x", companyName: "Old", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2001-01-01T00:00:00+00:00")],
            totalCount: 1, leadsComplete: true), now: now)
        if outlier.leadsAddedWeekly.weeks.count != 12 || outlier.leadsAddedWeekly.values.reduce(0, +) != 0 {
            problems.append("abmap: out-of-window timestamp must yield a zero-filled 12-week axis, not shift it")
        }

        // Divisor safety (the pinned bug class): all-zero / empty inputs — no NaN, no crash.
        let empty = ABLeadsData(inputs: DashboardInputs(leads: [], totalCount: 0, leadsComplete: true), now: now)
        if empty.emailedOfScrapedPct != 0 || empty.repliesOfEmailedPct != 0 {
            problems.append("abmap: empty inputs must yield 0% ratios")
        }
        if empty.emailedOfScrapedPct.isNaN || empty.repliesOfEmailedPct.isNaN {
            problems.append("abmap: ratios must never be NaN")
        }
        if empty.leadsAddedWeekly.values.reduce(0, +) != 0 { problems.append("abmap: empty leads → zero added series") }
        if !empty.recentLeads.isEmpty { problems.append("abmap: empty leads → empty recent list") }
        if !empty.bySource.isEmpty { problems.append("abmap: empty leads → empty breakdowns") }
        // The funnel keeps its shape on an empty book — four stages, all zero.
        if empty.byStatus.map(\.count) != [0, 0, 0, 0] { problems.append("abmap: empty leads → zero funnel") }
        if empty.breakdownScopeNote != nil { problems.append("abmap: complete/empty data → no scope note") }

        // WINDOWED snapshot: ONE population, always. There is no "keep the exact
        // full-table totals while nothing is filtered" path — it existed once, and
        // because the snapshot fetch no longer issues per-stage HEAD reads it put a
        // whole-table `scraped` in the header beside a window-scoped `scraped` in the
        // hero, with a reply rate of 500%. Pins the mixed-population bug class:
        // every headline figure must be counted over the SAME rows.
        let windowedInputs = DashboardInputs(
            leads: leads, totalCount: 200, leadsComplete: false,
            repliedLeadIDs: ["a", "z"], messagedSends: sends)
        let windowed = ABLeadsData(inputs: windowedInputs, now: now)
        if windowed.totals.scraped != 2 || windowed.totals.emailed != 2 || windowed.totals.replies != 1 {
            problems.append("abmap: a windowed load must count the WINDOW, never mix in full-table "
                + "figures (got \(windowed.totals.scraped)/\(windowed.totals.emailed)/\(windowed.totals.replies))")
        }
        if windowed.emailedDenominator != windowed.totals.scraped {
            problems.append("abmap: the hero denominator and the header 'scraped' must be the SAME number "
                + "(got \(windowed.emailedDenominator ?? -1) vs \(windowed.totals.scraped))")
        }
        if windowed.breakdownScopeNote?.contains("2 of 200") != true {
            problems.append("abmap: a windowed snapshot must disclose its scope (got \(windowed.breakdownScopeNote ?? "nil"))")
        }
        // Windowed AND filtered: same arithmetic, note retained.
        let windowedFiltered = ABLeadsData(inputs: windowedInputs,
                                           filter: LeadFilter(source: "sales-nav"), now: now)
        if windowedFiltered.totals.scraped != 1 || windowedFiltered.totals.emailed != 1 {
            problems.append("abmap: a FILTERED windowed load must count the matching window "
                + "(got \(windowedFiltered.totals.scraped)/\(windowedFiltered.totals.emailed))")
        }
        if windowedFiltered.breakdownScopeNote == nil {
            problems.append("abmap: a filtered windowed load must still disclose the window")
        }
        // The reply rate cannot exceed 100%: replies are intersected with the
        // EMAILED matching leads, so the numerator is a subset of the denominator
        // even when a lead has an inbound row but no send on record (a
        // data-integrity problem upstream that used to render as 200%).
        let earlyReply = ABLeadsData(inputs: DashboardInputs(
            leads: [LeadRow(id: "p", companyName: "P", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2026-07-20T12:00:00+00:00", personalized: true),
                    LeadRow(id: "q", companyName: "Q", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2026-07-20T12:00:00+00:00", personalized: true)],
            totalCount: 2, leadsComplete: true, repliedLeadIDs: ["p", "q"],
            messagedSends: [.init(leadID: "p", sentAt: "2026-07-21T09:00:00+00:00")]), now: now)
        if earlyReply.repliesOfEmailedPct > 100.0 {
            problems.append("abmap: the reply rate must not exceed 100% — replies are counted over the "
                + "leads that were actually emailed (got \(earlyReply.repliesOfEmailedPct)%)")
        }

        // percent() choke-point is total: negative/zero denominators never divide-by-zero.
        if ABLeadsData.percent(5, of: 0) != 0 { problems.append("abmap: percent(_, of: 0) must be 0") }
        if abs(ABLeadsData.percent(1, of: 4) - 25.0) > 0.001 { problems.append("abmap: percent math") }

        problems.append(contentsOf: leadFilterChecks())
        problems.append(contentsOf: regionKeyChecks())
        problems.append(contentsOf: leadSearchChecks())
        problems.append(contentsOf: viewModelChecks())
        problems.append(contentsOf: walkChecks())
        problems.append(contentsOf: frozenFixtureChecks())
        return problems
    }

    /// The two state machines this feature added had ZERO coverage — every other
    /// check here exercises pure derivation. These drive the real view models.
    private static func viewModelChecks() -> [String] {
        var problems: [String] = []

        // The freshness stamp must describe the DATA, not the attempt. It was
        // written by two of five refresh drivers, before the await, regardless of
        // outcome — so a deduped, cancelled or failed refresh advanced the clock
        // over unchanged numbers, which is the exact lie it was added to prevent.
        let vm = DashboardViewModel()
        if vm.loadedAt != nil { problems.append("vm: no load yet → no timestamp") }
        vm.loadFixture()
        guard let firstStamp = vm.loadedAt else {
            problems.append("vm: a successful load must stamp loadedAt")
            return problems
        }
        // A filter change re-derives; it does NOT make the data any newer.
        vm.apply(LeadFilter(source: "sales-nav"))
        if vm.loadedAt != firstStamp {
            problems.append("vm: a filter change must not advance the freshness stamp")
        }
        if vm.state.value?.effectiveFilter.source != "sales-nav" {
            problems.append("vm: apply() must re-derive through the new filter")
        }
        if vm.state.value?.matchingCount == vm.state.value.map({ _ in 0 }) {
            problems.append("vm: filtered snapshot should still match some leads")
        }

        // The LIVE load path, driven through an injected fetcher — its failure and
        // cancellation branches were unreachable before, which is how the exact
        // defect reported in round 1 (the stamp advancing on a failed load) could be
        // reinstated verbatim and still pass.
        struct StubError: Error {}
        let inputs = LeadsFixtureSource.inputs(now: abNow)

        let failing = DashboardViewModel(fetcher: { throw StubError() })
        if runMain({ await failing.load() }) == nil { problems.append("vm: failing.load() timed out") }
        if failing.loadedAt != nil {
            problems.append("vm: a FAILED load must not stamp loadedAt")
        }
        if failing.state.value != nil { problems.append("vm: a failed first load has no data") }

        let ok = DashboardViewModel(fetcher: { inputs })
        if runMain({ await ok.load() }) == nil { problems.append("vm: ok.load() timed out") }
        guard let liveStamp = ok.loadedAt else {
            problems.append("vm: a successful live load must stamp loadedAt")
            return problems
        }
        // …and a LATER failure must leave the stamp AND the data alone, showing the
        // stale banner over the numbers the stamp actually describes. A model whose
        // fetch succeeds once and fails after:
        let flakyBox = FlakyFetcher(inputs: inputs)
        let flaky = DashboardViewModel(fetcher: { try flakyBox.next() })
        if runMain({ await flaky.load() }) == nil { problems.append("vm: flaky.load() timed out") }
        let firstLive = flaky.loadedAt
        flakyBox.failFromNowOn()
        if runMain({ await flaky.load() }) == nil { problems.append("vm: flaky reload timed out") }
        if flaky.loadedAt != firstLive {
            problems.append("vm: a FAILED refresh must not advance the stamp over unchanged data")
        }
        if flaky.state.staleMessage == nil {
            problems.append("vm: a failed refresh with prior data must degrade to .stale, not .failed")
        }
        _ = liveStamp

        // Cancellation is not a failure: no stale banner, no stamp, no error state.
        let cancelled = DashboardViewModel(fetcher: { throw CancellationError() })
        if runMain({ await cancelled.load() }) == nil { problems.append("vm: cancelled.load() timed out") }
        if cancelled.loadedAt != nil { problems.append("vm: a cancelled load must not stamp") }
        if case .failed = cancelled.state {
            problems.append("vm: a cancelled load must not paint an error — that reports teardown as a fault")
        }

        // Search: a term below the minimum dismisses the RESULTS and keeps the text.
        let search = LeadSearchModel()
        search.fixtureRows = vm.snapshotLeads
        search.query = "Harborline"
        search.submit()
        guard case .results(_, let hits, _) = search.state, !hits.isEmpty else {
            problems.append("search-vm: an offline search over the fixture book must return hits")
            return problems
        }
        // The offline path must obey the same cap and order as the live query, or
        // `--fixture` can never exercise the "(60+)" surface or the newest-first
        // ordering — the two behaviours in that panel most likely to be wrong.
        // Asserted over a set deliberately LARGER than the cap: the fixture book
        // happens to yield exactly 60 per prefix, which would make this blind.
        let overCap = (0..<(LeadsRepository.searchResultLimit + 12)).map { i in
            LeadRow(id: "s\(i)", companyName: "Capco \(i)", firstName: nil, industry: nil,
                    leadSource: nil, city: nil, state: nil,
                    createdAt: String(format: "2026-07-%02dT00:00:00+00:00", (i % 28) + 1))
        }
        let capped = LeadsFixtureSource.search("Capco", in: overCap)
        if capped.count != LeadsRepository.searchResultLimit {
            problems.append("search-vm: the offline search must honour searchResultLimit "
                + "(got \(capped.count) of \(overCap.count))")
        }
        if capped.first?.createdAt ?? "" < capped.last?.createdAt ?? "" {
            problems.append("search-vm: offline hits must be newest-first like the live query")
        }
        // Results obey the tab's APPLIED lens — and everything the lens removes is
        // COUNTED, never silently dropped: a hidden lead must stay distinguishable
        // from a lead that isn't there, or the feature reintroduces the exact failure
        // it exists to prevent.
        let bookRows = [
            LeadRow(id: "tx", companyName: "Acme Texas", firstName: nil, industry: nil,
                    leadSource: "sales-nav", city: nil, state: "TX",
                    createdAt: "2026-07-20T00:00:00+00:00"),
            LeadRow(id: "fl", companyName: "Acme Florida", firstName: nil, industry: nil,
                    leadSource: "sales-nav", city: nil, state: "FL",
                    createdAt: "2026-07-19T00:00:00+00:00"),
        ]
        // The resolver is EMAILED-AWARE — hardcoding `emailed: false` made every
        // branch identical on exactly the dimension the 7.2 remap changed, and
        // the regression it hid (search hits understating their stage in the
        // DEFAULT no-filter state) sailed through (QA review). "tx" is treated
        // as sent-to; "fl" is not.
        let resolve: (LeadRow) -> LeadFacets = {
            LeadFacets(lead: $0, emailed: $0.id == "tx")
        }
        // NO-FILTER state: facets must still resolve (the status chip needs
        // them), and nothing is hidden.
        if case .results(_, let unfiltered, let hid) = LeadSearchModel.narrow(
            term: "acme", rows: bookRows, scope: .all, facets: resolve, ignoring: false) {
            if hid != 0 { problems.append("search-scope: inactive scope must hide nothing") }
            if unfiltered.first(where: { $0.leadID == "tx" })?.status != "Campaigned" {
                problems.append("search-scope: an unfiltered search hit must carry its REAL "
                    + "stage (got \(unfiltered.first(where: { $0.leadID == "tx" })?.status ?? "nil")) "
                    + "— skipping facet resolution understates every campaigned hit")
            }
        } else { problems.append("search-scope: unfiltered narrow returned no results") }
        let scoped = LeadSearchModel.narrow(term: "acme", rows: bookRows,
                                            scope: LeadFilter(region: "Texas"),
                                            facets: resolve, ignoring: false)
        guard case .results(_, let scopedHits, let hidden) = scoped else {
            problems.append("search-scope: expected results")
            return problems
        }
        if scopedHits.map(\.leadID) != ["tx"] || hidden != 1 {
            problems.append("search-scope: hits must be narrowed by the applied filter, with the "
                + "rest COUNTED (got \(scopedHits.map { $0.leadID ?? "?" }), hidden \(hidden))")
        }
        // The escape hatch really does widen it.
        if case .results(_, let allHits, let none) = LeadSearchModel.narrow(
            term: "acme", rows: bookRows, scope: LeadFilter(region: "Texas"),
            facets: resolve, ignoring: true), allHits.count != 2 || none != 0 {
            problems.append("search-scope: ignoring the filter must show every hit")
        }
        // No resolver (the snapshot read failed) → the filter CANNOT be evaluated, so
        // nothing may be hidden. Showing fewer leads than exist because we couldn't
        // classify them is the silent omission this must never make.
        if case .results(_, let unclassified, let hiddenBlind) = LeadSearchModel.narrow(
            term: "acme", rows: bookRows, scope: LeadFilter(region: "Texas"),
            facets: nil, ignoring: false), unclassified.count != 2 || hiddenBlind != 0 {
            problems.append("search-scope: with no facet resolver nothing may be hidden")
        }

        search.query = "H"
        search.submit()
        if search.query != "H" {
            problems.append("search-vm: a too-short term must not delete what the user typed")
        }
        if case .idle = search.state {} else {
            problems.append("search-vm: a too-short term must dismiss the results")
        }
        search.clear()
        if !search.query.isEmpty { problems.append("search-vm: clear() empties the box") }
        return problems
    }

    /// The paged WALKS, executed rather than reasoned about (see `StubURLProtocol`).
    /// Everything here was previously "assumed": cursor advance, termination, the
    /// page cap, dedupe, and whether a failed page actually reaches `ok: false`.
    private static func walkChecks() -> [String] {
        var problems: [String] = []

        @Sendable func client(_ handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Response?) -> SupabaseClient {
            SupabaseClient(baseURL: URL(string: "https://stub.invalid/rest/v1")!,
                           anonKey: "stub-anon", bearerKey: "stub-bearer",
                           session: StubURLProtocol.session(handler))
        }

        /// Two pages then an empty one — the shape every walk expects.
        @Sendable func pagedLeads(_ pages: [[String]]) -> @Sendable (URLRequest) -> StubURLProtocol.Response? {
            let bodies = pages.map { "[" + $0.joined(separator: ",") + "]" } + ["[]"]
            let counter = Counter()
            return { req in
                if req.value(forHTTPHeaderField: "Prefer") == "count=exact" {
                    let total = pages.reduce(0) { $0 + $1.count }
                    return .init(body: "[]", contentRange: "0-0/\(total)")
                }
                let i = counter.next()
                return .init(body: i < bodies.count ? bodies[i] : "[]")
            }
        }

        // A clean two-page walk: cursor advances by the LAST ROW's id, terminates on
        // the empty page, and reports complete.
        let repo = LeadsRepository(client: client(pagedLeads([[Self.leadJSON("a"), Self.leadJSON("b")],
                                                              [Self.leadJSON("c")]])))
        let walk = runAsync { try await repo.allLeads(pageSize: 2, maxPages: 5) }
        switch walk {
        case .failure(let error):
            problems.append("walk: a clean two-page walk threw (\(error))")
        case .success(let page):
            if page.rows.map(\.id).sorted() != ["a", "b", "c"] {
                problems.append("walk: expected every row across pages (got \(page.rows.map(\.id)))")
            }
            if !page.complete { problems.append("walk: a walk ending on an empty page is complete") }
            // The cursor must be carried forward — without it the walk re-reads page 1.
            let cursors = StubURLProtocol.queryValues("id").compactMap { $0 }
            if cursors != ["gt.b", "gt.c"] {
                problems.append("walk: cursor must advance by the last row's id (got \(cursors))")
            }
        }

        // DUPLICATES: what an insert mid-walk produces. They must be dropped, and
        // must NOT let the snapshot claim completeness (the row count would).
        let dupRepo = LeadsRepository(client: client(pagedLeads([[Self.leadJSON("a"), Self.leadJSON("b")],
                                                                 [Self.leadJSON("b"), Self.leadJSON("c")]])))
        if case .success(let page) = runAsync({ try await dupRepo.allLeads(pageSize: 2, maxPages: 5) }) {
            if page.rows.count != 3 {
                problems.append("walk: a repeated row must be deduped (got \(page.rows.count))")
            }
        } else { problems.append("walk: dup walk threw") }

        // PAGE CAP: a walk that never sees an empty page is NOT complete.
        let capCounter = Counter()
        let capRepo = LeadsRepository(client: client({ _ in
            .init(body: "[" + Self.leadJSON("cap-\(capCounter.next())") + "]")
        }))
        if case .success(let page) = runAsync({ try await capRepo.allLeads(pageSize: 1, maxPages: 3) }) {
            if page.complete { problems.append("walk: hitting the page cap must NOT read as complete") }
            if page.rows.count != 3 { problems.append("walk: cap should stop after maxPages pages") }
        } else { problems.append("walk: cap walk threw") }

        // A FAILED page reaches `ok: false` — the producer half of the flat-zero
        // trend. A mutation flipping this return survived the suite before the walk
        // was executable.
        let badRepo = LeadsRepository(client: client({ _ in .init(body: "not json") }))
        let sends = runAsyncValue { await badRepo.messagedSendsResult(pageSize: 2, maxPages: 3) }
        if sends?.ok != false {
            problems.append("walk: an unparseable sent-events page must report ok:false")
        }
        let ids = runAsyncValue { await badRepo.leadIDsResult(table: "v_cec_lead_interactions", filters: [],
                                                              pageSize: 2, maxPages: 3) }
        if ids?.ok != false {
            problems.append("walk: an unparseable lead_id page must report ok:false")
        }
        // An HTTP error is also a degraded read, not an empty one.
        let errRepo = LeadsRepository(client: client({ _ in .init(status: 401, body: "{}") }))
        let errIDs = runAsyncValue { await errRepo.leadIDsResult(table: "v_cec_lead_interactions", filters: []) }
        if errIDs?.ok != false || errIDs?.ids.isEmpty != true {
            problems.append("walk: a 401 must degrade, not return a confident empty set")
        }

        // The page CAP on the two supplementary walks. `allLeads` was pinned and
        // these two — one call site over — were not, which is the "list short by
        // one" tell: the cap means the set is a FLOOR, so it must report ok:false.
        let endless = LeadsRepository(client: client({ req in
            let table = req.url?.path.split(separator: "/").last ?? ""
            if table == "v_cec_sent_events" {
                return .init(body: #"[{"id":"\#(UUID().uuidString)","lead_id":"L","sent_at":"2026-07-20T00:00:00+00:00"}]"#)
            }
            return .init(body: #"[{"id":"\#(UUID().uuidString)","lead_id":"L"}]"#)
        }))
        if runAsyncValue({ await endless.leadIDsResult(table: "v_cec_lead_interactions", filters: [],
                                                       pageSize: 1, maxPages: 2) })?.ok != false {
            problems.append("walk: leadIDsResult hitting the page cap must report ok:false (a floor, not the truth)")
        }
        if runAsyncValue({ await endless.messagedSendsResult(pageSize: 1, maxPages: 2) })?.ok != false {
            problems.append("walk: messagedSendsResult hitting the page cap must report ok:false")
        }
        // A non-empty page with NO usable cursor cannot be walked past — degrade
        // rather than silently return a prefix.
        let noCursor = LeadsRepository(client: client({ _ in .init(body: #"[{"lead_id":"L"}]"#) }))
        if runAsyncValue({ await noCursor.leadIDsResult(table: "v_cec_lead_interactions", filters: [],
                                                        pageSize: 2, maxPages: 3) })?.ok != false {
            problems.append("walk: a page with no cursor must report ok:false, not a silent prefix")
        }

        // fetch() must send BOTH replied-set predicates over the wire. Pinned
        // BEHAVIOURALLY at the request layer — deleting interaction_type from
        // `repliedFilters` left the whole suite green while a Cal booking or
        // magnet view counted as a reply (delta round 1, mutation-proven).
        let routed = LeadsRepository(client: client({ req in
            let table = req.url?.path.split(separator: "/").last ?? ""
            if req.value(forHTTPHeaderField: "Prefer") == "count=exact" {
                return .init(body: "[]", contentRange: "0-0/1")
            }
            switch table {
            case "v_cec_leads":
                let cursor = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains { $0.name == "id" } ?? false
                return .init(body: cursor ? "[]" : "[" + Self.leadJSON("f1") + "]")
            default:
                return .init(body: "[]")
            }
        }))
        switch runAsync({ try await routed.fetch() }) {
        case .failure(let error):
            problems.append("walk: routed fetch() threw (\(error))")
        case .success:
            let interactionReqs = StubURLProtocol.requests.compactMap { req -> URLComponents? in
                guard let url = req.url, url.path.hasSuffix("v_cec_lead_interactions") else { return nil }
                return URLComponents(url: url, resolvingAgainstBaseURL: false)
            }
            if interactionReqs.isEmpty {
                problems.append("walk: fetch() never queried v_cec_lead_interactions")
            }
            for comps in interactionReqs {
                let items = comps.queryItems ?? []
                if !items.contains(where: { $0.name == "direction" && $0.value == "eq.inbound" })
                    || !items.contains(where: { $0.name == "interaction_type" && $0.value == "eq.email" }) {
                    problems.append("walk: the replied-set request must carry BOTH "
                        + "direction=eq.inbound AND interaction_type=eq.email — a Cal "
                        + "booking or magnet view is not a reply (got \(comps.query ?? ""))")
                    break
                }
            }
        }

        // THE TWO-KEY WIRE CONTRACT (6.1 intel, learned live at the 7.2
        // install acceptance): the gateway validates the `apikey` HEADER
        // against KNOWN keys, so the reader JWT there is a hard 401 before
        // PostgREST runs. `apikey` must carry the ANON key and the bearer must
        // carry the SCOPED credential — asserted on the actual wire request,
        // exactly like the Python factory's AuthMechanism pins.
        if let lastReq = StubURLProtocol.requests.last {
            if lastReq.value(forHTTPHeaderField: "apikey") != "stub-anon" {
                problems.append("walk: the apikey header must carry the ANON key "
                    + "(got \(lastReq.value(forHTTPHeaderField: "apikey") ?? "nil")) — "
                    + "a class JWT there is rejected by the gateway outright")
            }
            if lastReq.value(forHTTPHeaderField: "Authorization") != "Bearer stub-bearer" {
                problems.append("walk: the Authorization header must carry the BEARER "
                    + "credential (got \(lastReq.value(forHTTPHeaderField: "Authorization") ?? "nil"))")
            }
        } else {
            problems.append("walk: no captured request to assert the two-key wire contract on")
        }

        // fetch() must THROW on an empty book — the fail-closed layer for the
        // repo's most-repeated defect class (a grant blackout returning 200 []
        // rendering as a clean zeroed dashboard). compose's chip is the second
        // layer and is pinned separately; this pins the layer whose artifact is
        // a thrown load, not a chip (delta round 2 — the guard was deletable
        // under a green suite).
        let emptyBook = LeadsRepository(client: client({ req in
            if req.value(forHTTPHeaderField: "Prefer") == "count=exact" {
                return .init(body: "[]", contentRange: "0-0/0")
            }
            return .init(body: "[]")
        }))
        if case .success = runAsync({ try await emptyBook.fetch() }) {
            problems.append("walk: fetch() over an empty book must THROW (fail closed) — "
                + "a 200-[] grant blackout must never compose a zeroed dashboard")
        }
        return problems
    }

    /// One stubbed `v_cec_leads` row. Nonisolated so the stub's request handler —
    /// which runs off the main actor — can build pages.
    private nonisolated static func leadJSON(_ id: String,
                                             created: String = "2026-07-20T00:00:00+00:00") -> String {
        #"{"id":"\#(id)","company_name":"C\#(id)","created_at":"\#(created)","personalized":false,"has_research":false}"#
    }

    /// Run an async throwing call to completion from the synchronous selftest.
    ///
    /// Pumps the run loop rather than blocking on a semaphore. `SelfTest` is
    /// `@MainActor` and runs pre-boot ON the main thread, so a semaphore wait blocks
    /// the main actor — and any body that needs the main actor then deadlocks until
    /// the timeout (measured: 22.3 s, returning a false failure). That is exactly
    /// what a `@MainActor` view model is, i.e. precisely the code whose state machine
    /// went untested. Pumping lets main-actor work run while we wait.
    private static func runAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let box = ResultBox<T>()
        Task {
            do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(20)
        while box.get() == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return box.get() ?? .failure(CancellationError())
    }

    /// Same, for a `@MainActor` body (view models). Kept separate so the isolation
    /// is explicit at the call site rather than inferred.
    private static func runMain<T: Sendable>(_ body: @escaping @MainActor () async -> T) -> T? {
        let box = ResultBox<T>()
        Task { @MainActor in box.set(.success(await body())) }
        let deadline = Date().addingTimeInterval(20)
        while box.get() == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return try? box.get()?.get()
    }

    private static func runAsyncValue<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
        try? runAsync { await body() }.get()
    }

    /// Locked: on the timeout path the waiting thread reads while the task may still
    /// be writing, which is a live data race however unlikely it is to bite.
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func set(_ v: Result<T, Error>) { lock.lock(); value = v; lock.unlock() }
        func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Succeeds until told otherwise — models the refresh that works, then doesn't.
    private final class FlakyFetcher: @unchecked Sendable {
        struct Failure: Error {}
        private let lock = NSLock()
        private let inputs: DashboardInputs
        private var failing = false
        init(inputs: DashboardInputs) { self.inputs = inputs }
        func failFromNowOn() { lock.lock(); failing = true; lock.unlock() }
        func next() throws -> DashboardInputs {
            lock.lock(); let f = failing; lock.unlock()
            if f { throw Failure() }
            return inputs
        }
    }

    /// Monotonic page index for the stub (no `Date`/random in selftests).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var i = 0
        func next() -> Int { lock.lock(); defer { i += 1; lock.unlock() }; return i }
    }

    /// Frozen preview fixtures are DATA, and data drifts: a field added to the
    /// struct defaults to zero in any hand-listed fixture, and the still then ships
    /// a figure that contradicts the chart above it (this shipped once — a messaged
    /// curve footed by "0 leads reached").
    private static func frozenFixtureChecks() -> [String] {
        var problems: [String] = []
        for (name, d) in [("ab", ABLeadsData.ab), ("abFiltered", ABLeadsData.abFiltered),
                          ("abDegraded", ABLeadsData.abDegraded)] {
            if d.leadsMessagedWeekly.values.reduce(0, +) > 0 && d.leadsMessagedTotal == 0 {
                problems.append("fixture \(name): a non-zero messaged curve with a 0 distinct-lead "
                    + "total — a derived field defaulted instead of being computed")
            }
            if d.matchingCount == 0 && !d.recentLeads.isEmpty {
                problems.append("fixture \(name): rows rendered with matchingCount 0")
            }
            if d.emailedDenominator == 0 && d.totals.scraped > 0 {
                problems.append("fixture \(name): hero denominator contradicts the header total")
            }
        }
        // The filtered still must actually be filtered, or it demonstrates nothing.
        if !ABLeadsData.abFiltered.effectiveFilter.isActive
            || ABLeadsData.abFiltered.matchingCount == 0 {
            problems.append("fixture abFiltered: must render a NARROWED, non-empty view")
        }
        return problems
    }

    /// The filter contract: every headline figure is derived from the SAME filtered
    /// set as the list (the mixed-view bug class), lanes classify correctly, facet
    /// menus count against the other dimensions. (The lane-degradation family
    /// left with its mechanism in 7.2 — lane inputs are essential now.)
    private static func leadFilterChecks() -> [String] {
        var problems: [String] = []
        let now = abNow

        func lead(_ id: String, source: String, industry: String, state: String?,
                  location: String? = nil, deepening: String = "none",
                  personalized: Bool = false, hasResearch: Bool = false,
                  created: String) -> LeadRow {
            LeadRow(id: id, companyName: "C\(id)", firstName: nil, industry: industry,
                    leadSource: source, city: nil, state: state, createdAt: created,
                    deepening: deepening, personalized: personalized,
                    hasResearch: hasResearch, location: location)
        }
        // 4 leads: 2 Florida (one deep + emailed + replied, one standard),
        // 1 Texas (from free-text location), 1 unpersonalized California.
        let leads = [
            lead("a", source: "gmaps-leads", industry: "Solar", state: "FL",
                 deepening: "in_progress", personalized: true, hasResearch: true,
                 created: "2026-07-20T12:00:00+00:00"),
            lead("b", source: "gmaps-leads", industry: "Solar", state: "Florida",
                 personalized: true, hasResearch: true,
                 created: "2026-07-20T12:00:00+00:00"),
            lead("c", source: "sales-nav", industry: "Biotech", state: nil,
                 location: "Austin, Texas, United States",
                 personalized: true, hasResearch: true,
                 created: "2026-07-13T12:00:00+00:00"),
            lead("d", source: "sales-nav", industry: "Biotech", state: "CA",
                 created: "2026-07-06T12:00:00+00:00"),
        ]
        let inputs = DashboardInputs(
            leads: leads, totalCount: 4, leadsComplete: true,
            repliedLeadIDs: ["a", "b"],
            messagedSends: [
                .init(leadID: "a", sentAt: "2026-07-21T09:00:00+00:00"),
                .init(leadID: "b", sentAt: "2026-07-21T09:00:00+00:00"),
            ])

        // Unfiltered baseline.
        let all = ABLeadsData(inputs: inputs, now: now)
        if all.totals.scraped != 4 || all.totals.emailed != 2 || all.totals.replies != 2 {
            problems.append("filter: unfiltered totals wrong (\(all.totals.scraped)/\(all.totals.emailed)/\(all.totals.replies))")
        }
        // "FL" and "Florida" are the same place — a filter that splits them is
        // useless on a book two scrapers wrote.
        if all.byRegion.first(where: { $0.label == "Florida" })?.count != 2 {
            problems.append("filter: FL and Florida must canonicalize into one region (got \(all.byRegion.map { "\($0.label)=\($0.count)" }))")
        }

        // Region filter → EVERY figure narrows together.
        let florida = ABLeadsData(inputs: inputs, filter: LeadFilter(region: "Florida"), now: now)
        if florida.matchingCount != 2 || florida.recentLeads.count != 2 {
            problems.append("filter: region must narrow the list (got \(florida.matchingCount)/\(florida.recentLeads.count))")
        }
        if florida.totals.scraped != 2 || florida.totals.emailed != 2 || florida.totals.replies != 2 {
            problems.append("filter: HERO STATS must move with the filter — the whole point of the bar "
                + "(got \(florida.totals.scraped)/\(florida.totals.emailed)/\(florida.totals.replies))")
        }
        if abs(florida.emailedOfScrapedPct - 100.0) > 0.001 {
            problems.append("filter: ratio must be computed over the filtered set (got \(florida.emailedOfScrapedPct))")
        }
        if florida.leadsAddedWeekly.values.reduce(0, +) != 2 {
            problems.append("filter: the added trend must narrow with the filter")
        }
        // Both sends are to Florida leads — the whole trend survives this lens.
        if florida.leadsMessagedWeekly.values.reduce(0, +) != 2 {
            problems.append("filter: the messaged trend must cover the matching leads' sends "
                + "(got \(florida.leadsMessagedWeekly.values.reduce(0, +)))")
        }
        // EVERY panel counts the filtered set — asserted by TOTAL, not by row count.
        // QA's mutation run proved the earlier `.count` checks were blind: swapping
        // `byRegion` to the unfiltered facets left the suite green, and those are
        // precisely the panels this feature added. A sum can't be fooled by two
        // categories collapsing to the same shape.
        for (name, items, expected) in [
            ("bySource", florida.bySource, 2), ("byIndustry", florida.byIndustry, 2),
            ("byRegion", florida.byRegion, 2),
        ] {
            let total = items.reduce(0) { $0 + $1.count }
            if total != expected {
                problems.append("filter: \(name) must total the FILTERED set (got \(total), want \(expected))")
            }
        }
        // The funnel narrows too: Scraped = the 2 matching, Campaigned = the 2 emailed.
        if florida.byStatus.map(\.count) != [2, 2, 2, 2] {
            problems.append("filter: the funnel must count the FILTERED set (got \(florida.byStatus.map(\.count)))")
        }
        if florida.byRegion.first?.label != "Florida" {
            problems.append("filter: byRegion must describe the filtered set (got \(florida.byRegion.map(\.label)))")
        }
        // The hero's `emailed` must be filtered too. The fixture is deliberately
        // NON-degenerate for this: 2 of the 4 leads are campaigned and only ONE of
        // those is in California, so an unfiltered `emailed` reads 2 where the
        // filtered answer is 0 — the earlier fixture had every campaigned lead
        // inside the filtered region, which made the assertion unfalsifiable.
        let california = ABLeadsData(inputs: inputs, filter: LeadFilter(region: "California"), now: now)
        if california.matchingCount != 1 || california.totals.emailed != 0 {
            problems.append("filter: hero 'emailed' must count only MATCHING emailed leads "
                + "(got \(california.totals.emailed) over \(california.matchingCount) leads)")
        }
        if california.totals.replies != 0 {
            problems.append("filter: replies must narrow with the filter (got \(california.totals.replies))")
        }
        // Sends to leads outside the lens are not this view's trend.
        if california.leadsMessagedWeekly.values.reduce(0, +) != 0 {
            problems.append("filter: the messaged trend must exclude sends to filtered-out leads "
                + "(got \(california.leadsMessagedWeekly.values.reduce(0, +)))")
        }

        // Lane classification: deep beats standard; no opener → none.
        let deep = ABLeadsData(inputs: inputs, filter: LeadFilter(lane: .deep), now: now)
        if deep.matchingCount != 1 || deep.recentLeads.first?.leadID != "a" {
            problems.append("filter: deep lane must select exactly the deep-cohort lead (got \(deep.matchingCount))")
        }
        let standard = ABLeadsData(inputs: inputs, filter: LeadFilter(lane: .standard), now: now)
        if standard.matchingCount != 2 {
            problems.append("filter: standard lane = has an opener but no deep run (got \(standard.matchingCount))")
        }
        let unpersonalized = ABLeadsData(inputs: inputs, filter: LeadFilter(lane: LeadFilter.Lane.none), now: now)
        if unpersonalized.matchingCount != 1 || unpersonalized.recentLeads.first?.leadID != "d" {
            problems.append("filter: 'not personalized' must select the lead with no opener (got \(unpersonalized.matchingCount))")
        }

        // Free-text LinkedIn location must land in a real region bucket, not Unknown.
        let texas = ABLeadsData(inputs: inputs, filter: LeadFilter(region: "Texas"), now: now)
        if texas.matchingCount != 1 || texas.recentLeads.first?.leadID != "c" {
            problems.append("filter: a sales-nav free-text location must still be filterable by region")
        }

        // Dimensions AND together, and an impossible combination is an honest zero
        // (not a crash, not the unfiltered view).
        let impossible = ABLeadsData(inputs: inputs,
                                     filter: LeadFilter(region: "Florida", source: "sales-nav"), now: now)
        if impossible.matchingCount != 0 || !impossible.recentLeads.isEmpty
            || impossible.totals.scraped != 0 || impossible.emailedOfScrapedPct != 0 {
            problems.append("filter: contradictory dimensions must yield an empty, non-NaN view "
                + "(got \(impossible.matchingCount) leads, \(impossible.emailedOfScrapedPct)%)")
        }

        // Facet menus count against the OTHER dimensions: with Florida picked, the
        // source menu offers only sources present in Florida — never a choice that
        // would return nothing.
        let facets = florida.facets
        if facets.sources.map(\.value) != ["gmaps-leads"] {
            problems.append("filter: source menu must count within the other active dimensions (got \(facets.sources.map(\.value)))")
        }
        // …but the REGION menu itself still offers every region, or picking a
        // different one would be impossible once one is chosen.
        if Set(facets.regions.map(\.value)) != ["Florida", "Texas", "California"] {
            problems.append("filter: a dimension's own menu must ignore its own selection (got \(facets.regions.map(\.value)))")
        }
        if facets.regions.first?.value != "Florida" || facets.regions.first?.count != 2 {
            problems.append("filter: facet options must be largest-first with counts (got \(facets.regions.map { "\($0.value)=\($0.count)" }))")
        }
        // Unfiltered, the lane menu counts the whole book: 1 deep, 2 standard, 1 none.
        if all.facets.lanes.map(\.count) != [1, 2, 1] {
            problems.append("filter: lane facet counts wrong (got \(all.facets.lanes.map { "\($0.lane.rawValue)=\($0.count)" }))")
        }
        // Under the Florida filter it counts only Florida's leads — and drops
        // "not personalized" entirely, because picking it there would show nothing.
        if facets.lanes.map({ "\($0.lane.rawValue)=\($0.count)" }) != ["deep=1", "standard=1"] {
            problems.append("filter: lane menu must count within the other dimensions "
                + "(got \(facets.lanes.map { "\($0.lane.rawValue)=\($0.count)" }))")
        }

        // (The degraded-lane suppression machinery is structurally gone since 7.2:
        // lane inputs ride the essential v_cec_leads read, so a lane can no longer
        // degrade independently of the book. The replied/sent degradation pins
        // live in leadsComposeChecks.)
        if ABLeadsData.abFiltered.listCaption != ABLeadsData.abFiltered.effectiveFilter.summary {
            problems.append("filter: the list caption must be the APPLIED filter's summary")
        }
        // A degraded load names what is understated rather than showing a confident
        // zero — the flag alone rendered nowhere.
        let degradedInputs = LeadsRepository.compose(
            leads: leads, totalCount: leads.count, leadsComplete: true,
            replied: ([], ok: false),
            messaged: (inputs.messagedSends, ok: true))
        let degraded = ABLeadsData(inputs: degradedInputs, now: now)
        if !degradedInputs.partial || degraded.degradedReads.isEmpty {
            problems.append("filter: a degraded load must carry named reads for the UI to surface")
        }

        // The list is capped, and says so through matchingCount ≠ rendered rows.
        let many = (0..<(ABLeadsData.listCap + 5)).map {
            lead("m\($0)", source: "gmaps-leads", industry: "Solar", state: "FL",
                 created: "2026-07-20T12:00:00+00:00")
        }
        let capped = ABLeadsData(inputs: DashboardInputs(leads: many, totalCount: many.count,
                                                         leadsComplete: true), now: now)
        if capped.recentLeads.count != ABLeadsData.listCap || capped.matchingCount != many.count {
            problems.append("filter: the list must cap at listCap while reporting the true match count "
                + "(rendered \(capped.recentLeads.count), matching \(capped.matchingCount))")
        }

        // The "Other" fold: the tail branch runs on every real render (the live book
        // derives ~76 regions against a topN of 6) and had no coverage at all —
        // deleting the fold entirely left the suite green while the panel silently
        // stopped totalling the set.
        let manyCategories = (0..<12).map { i in
            lead("o\(i)", source: "src-\(i)", industry: "ind-\(i)", state: "FL",
                 created: "2026-07-20T12:00:00+00:00")
        }
        let folded = ABLeadsData(inputs: DashboardInputs(
            leads: manyCategories, totalCount: 12, leadsComplete: true), now: now)
        if folded.bySource.reduce(0, { $0 + $1.count }) != 12 {
            problems.append("filter: a breakdown with more categories than topN must fold the tail "
                + "into 'Other', still totalling the set (got \(folded.bySource.reduce(0) { $0 + $1.count }))")
        }
        if folded.bySource.last?.label != "Other" {
            problems.append("filter: the folded tail must be labelled 'Other' (got \(folded.bySource.map(\.label)))")
        }
        // …and the MENU must not truncate at all, or a facet becomes unreachable
        // (the live region menu was dropping roughly half its options silently).
        if folded.facets.sources.count != 12 {
            problems.append("filter: facet menus must offer every value, not a top-N slice "
                + "(got \(folded.facets.sources.count) of 12)")
        }
        // A selection emptied by another dimension still appears in its own menu —
        // otherwise it can be cleared but never re-picked.
        let stranded = ABLeadsData(inputs: inputs,
                                   filter: LeadFilter(region: "Florida", source: "sales-nav"), now: now)
        if !stranded.facets.sources.contains(where: { $0.value == "sales-nav" }) {
            problems.append("filter: an active selection must remain in its own menu even at count 0")
        }

        // Row labels and facet labels are the SAME string: the row used to render a
        // null column as "—" while the panel and the menu called it "Unknown", so
        // picking "Unknown" showed rows labelled something else.
        let nullish = ABLeadsData(inputs: DashboardInputs(
            leads: [LeadRow(id: "n", companyName: "N", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2026-07-20T12:00:00+00:00")],
            totalCount: 1, leadsComplete: true), filter: LeadFilter(source: LeadFacets.unknown), now: now)
        if nullish.matchingCount != 1 || nullish.recentLeads.first?.source != LeadFacets.unknown
            || nullish.recentLeads.first?.industry != LeadFacets.unknown {
            problems.append("filter: a null column must render in the row with the SAME label the "
                + "menu and panel use (got source '\(nullish.recentLeads.first?.source ?? "nil")')")
        }

        // Messaged-trend total counts LEADS, not lead-weeks: one lead messaged in
        // three different weeks is one lead reached.
        let repeatSends = ABLeadsData(inputs: DashboardInputs(
            leads: [lead("r", source: "gmaps-leads", industry: "Solar", state: "FL",
                         personalized: true, created: "2026-07-06T12:00:00+00:00")],
            totalCount: 1, leadsComplete: true,
            messagedSends: [.init(leadID: "r", sentAt: "2026-07-08T09:00:00+00:00"),
                            .init(leadID: "r", sentAt: "2026-07-15T09:00:00+00:00"),
                            .init(leadID: "r", sentAt: "2026-07-22T09:00:00+00:00")]), now: now)
        if repeatSends.leadsMessagedWeekly.values.reduce(0, +) != 3 {
            problems.append("filter: the weekly series counts distinct leads PER WEEK (expected 3 lead-weeks)")
        }
        if repeatSends.leadsMessagedTotal != 1 {
            problems.append("filter: the messaged total must count DISTINCT leads over the window, not "
                + "sum the weekly buckets (got \(repeatSends.leadsMessagedTotal))")
        }

        // LeadFilter's own contract.
        if LeadFilter.all.isActive { problems.append("filter: the empty filter must not read as active") }
        if LeadFilter(region: "Texas").summary != "Texas" {
            problems.append("filter: summary should name the active dimensions")
        }
        if LeadFilter(lane: .deep, region: "Texas").summary != "Deep lane · Texas" {
            problems.append("filter: summary should join every active dimension")
        }
        return problems
    }

    /// Region derivation goldens (`RegionKey`). Both halves matter: the shapes it
    /// must place, and the shapes it must REFUSE to guess at.
    private static func regionKeyChecks() -> [String] {
        var problems: [String] = []
        func check(_ name: String, city: String? = nil, state: String? = nil,
                   location: String? = nil, country: String? = nil, _ expected: String) {
            let got = RegionKey.region(city: city, state: state, location: location, country: country)
            if got != expected {
                problems.append("region \(name): got '\(got)', want '\(expected)'")
            }
        }
        // The state column wins, in either scraper's spelling.
        check("abbrev", state: "FL", "Florida")
        check("full name", state: "Florida", "Florida")
        check("lowercase", state: "florida", "Florida")
        check("padded", state: "  CA  ", "California")
        // LinkedIn free text.
        check("city/state/country", location: "Austin, Texas, United States", "Texas")
        check("county", location: "Los Angeles County, California, United States", "California")
        check("metro suffix", location: "Austin, Texas Metropolitan Area", "Texas")
        check("named metro", location: "San Francisco Bay Area", "California")
        check("greater metro", location: "Greater Houston", "Texas")
        check("metroplex", location: "Dallas-Fort Worth Metroplex", "Texas")
        check("foreign", location: "London, England, United Kingdom", "United Kingdom")
        check("country only", location: "Ireland", "Ireland")
        check("US only", location: "United States", "United States")
        // A bare two-letter token is NOT trusted as a state without a US marker:
        // "DE" is Delaware in one book and Germany in the other.
        check("ambiguous abbrev", location: "Berlin, DE", "DE")
        check("abbrev with US marker", location: "Miami, FL, United States", "Florida")
        // …and the COUNTRY COLUMN is a US marker too. source-jobsignal writes
        // location "San Francisco, CA" + country "US" with no state; ignoring the
        // column split three live leads into a bucket named "CA" sitting beside
        // "California".
        check("abbrev + country column", location: "San Francisco, CA", country: "US", "California")
        check("abbrev, no corroboration", location: "San Francisco, CA", "CA")
        // Georgia is both a US state and a country: matching the name without US
        // corroboration would merge Tbilisi into Atlanta's bucket.
        check("georgia the country", location: "Tbilisi, Georgia", "Georgia (country)")
        check("georgia the state", location: "Atlanta, Georgia, United States", "Georgia")
        check("georgia via country column", location: "Atlanta, Georgia", country: "USA", "Georgia")
        // Fallbacks.
        check("country column", country: "USA", "United States")
        check("country column literal", country: "Canada", "Canada")
        check("nothing", "Unknown")
        check("blank strings", state: "  ", location: "", country: "  ", "Unknown")
        // City alone is never enough to name a region — refusing to guess is the
        // contract (a wrong bucket is worse than an honest Unknown).
        check("city only", city: "Tampa", "Unknown")
        return problems
    }

    /// Search: the sanitizer (a filter-grammar injection guard) and the query it
    /// builds. Every denied character below can rewrite the PostgREST `or=()`
    /// predicate or turn the search into a full-table dump.
    private static func leadSearchChecks() -> [String] {
        var problems: [String] = []
        func term(_ raw: String) -> String? { LeadsRepository.searchTerm(raw) }

        if term("Acme Solar") != "Acme Solar" { problems.append("search: a plain term must pass through unchanged") }
        if term("  Acme   Solar  ") != "Acme Solar" { problems.append("search: whitespace must collapse") }
        if term("O'Brien Sons-Ltd.") != "O'Brien Sons-Ltd." {
            problems.append("search: punctuation that is safe in a value must survive (got \(term("O'Brien Sons-Ltd.") ?? "nil"))")
        }
        // Injection: a comma would start a NEW predicate inside or=(…).
        if term("acme,email.ilike.*@*") != "acme email.ilike. @" {
            problems.append("search: the or() grammar characters must be stripped (got \(term("acme,email.ilike.*@*") ?? "nil"))")
        }
        for hostile in ["a,b", "a(b", "a)b", "a*b", "a%b", "a\\b", "a\"b"] {
            if let cleaned = term(hostile),
               cleaned.contains(where: { ",()*%\\\"".contains($0) }) {
                problems.append("search: '\(hostile)' left a grammar character in '\(cleaned)'")
            }
        }
        // A lone wildcard is not a search — it must not become `ilike.**`.
        if term("%") != nil || term("*") != nil || term(" ") != nil {
            problems.append("search: a wildcard-only/blank term must not run a query")
        }
        if term("a") != nil { problems.append("search: a single character is below the minimum") }
        if term(String(repeating: "x", count: 500))?.count != LeadsRepository.searchTermLimit {
            problems.append("search: an over-long term must be capped at searchTermLimit")
        }
        if term("Acme\nSolar\tCo") != "Acme Solar Co" {
            problems.append("search: newlines/tabs must collapse to spaces, not vanish")
        }
        // `_` is LIKE's single-char wildcard: kept (it can only widen a match, and
        // stripping it breaks a literal search for a name containing one) — but a
        // term made ONLY of wildcards is not a search.
        if term("acme_corp") != "acme_corp" { problems.append("search: '_' must be preserved") }
        if term("__") != nil || term("____") != nil {
            problems.append("search: an all-wildcard term must not run a query (it matches everything)")
        }
        // `&` and `=` are dropped rather than trusted to `URLComponents`' encoding,
        // so the injection guarantee survives a change of HTTP layer; `+` is dropped
        // because PostgREST decodes it as a space, which turned "AT+T" into a search
        // for "AT T" and answered "no lead matches" — a false negative, in the one
        // feature that must never produce one.
        for (raw, why) in [("acme&or=(id.eq.1", "&"), ("acme=x", "="), ("AT+T", "+")] {
            if let cleaned = term(raw), cleaned.contains(where: { "&=+".contains($0) }) {
                problems.append("search: '\(why)' must not survive sanitisation (got \(cleaned))")
            }
        }
        // The output feeds `ilike.*TERM*`: if a wildcard ever survives, BOTH the
        // injection guard and the ReDoS guard are reopened at once. Pin the property,
        // not the individual characters.
        for hostile in ["a%b", "a*b", "%%%", "a\\%b", "50% off", "5*5"] {
            if let cleaned = term(hostile), cleaned.contains(where: { $0 == "%" || $0 == "*" }) {
                problems.append("search: sanitised output must never contain a LIKE wildcard (got \(cleaned))")
            }
        }

        // The built filter covers company AND person name, and stays one group.
        let filter = LeadsRepository.searchFilter("Acme")
        for column in ["company_name", "full_name", "first_name", "last_name", "email"]
        where !filter.contains("\(column).ilike.*Acme*") {
            problems.append("search: filter must cover \(column) (got \(filter))")
        }
        if !filter.hasPrefix("(") || !filter.hasSuffix(")") || filter.dropLast().dropFirst().contains("(") {
            problems.append("search: filter must be exactly one or() group (got \(filter))")
        }
        return problems
    }

    /// Exercises the Leads compose seam: supplementary results carry an `ok` flag,
    /// a FAILED read (not an EMPTY table) marks the load partial, and a failed LANE
    /// read additionally marks it degraded — because empty lane sets are not "no
    /// deep-lane leads", they are "we don't know", and the two must not render the
    /// same.
    private static func leadsComposeChecks(sampleLeads: [LeadRow]) -> [String] {
        var problems: [String] = []

        // Every supplementary read ok (even when empty) → NOT partial.
        let clean = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            replied: (["a"], ok: true))
        if clean.partial {
            problems.append("leads-compose: ok reads must not mark partial")
        }
        if clean.repliedLeadIDs != ["a"] {
            problems.append("leads-compose: replied id set not packaged through")
        }
        if !clean.leadsComplete { problems.append("leads-compose: a full page walk over the whole table is complete") }

        // A short walk is NOT a complete snapshot even if paging ended cleanly:
        // rows written mid-walk (or invisible to RLS) leave us below the total.
        let short = LeadsRepository.compose(
            leads: sampleLeads, totalCount: 720, leadsComplete: true)
        if short.leadsComplete {
            problems.append("leads-compose: fewer rows than the exact total must not read as complete")
        }
        // …and hitting the page cap is never complete.
        let cappedWalk = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: false)
        if cappedWalk.leadsComplete {
            problems.append("leads-compose: a capped page walk must not read as complete")
        }

        // A failed REPLIES read is partial and NAMES itself — the reply figure is
        // understated, and a bare flag renders nowhere.
        let repliesFailed = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            replied: ([], ok: false))
        if !repliesFailed.partial || !repliesFailed.degradedReads.contains("replies") {
            problems.append("leads-compose: a failed replies read must mark partial and name itself "
                + "(got \(repliesFailed.degradedReads))")
        }

        // leadIDs (the replied-set page parser): an unparseable 2xx body is a
        // FAILED page (nil), never an empty one — same contract as `tally`, and it
        // matters more here (an "empty" lane set misclassifies every lead).
        if LeadsRepository.leadIDs(Data("not json".utf8)) != nil {
            problems.append("leads-ids: garbage body must be nil (failed read), not empty")
        }
        let idPage = LeadsRepository.leadIDs(
            Data(#"[{"id":"1","lead_id":"a"},{"id":"2","lead_id":"a"},{"id":"3","lead_id":" "},{"id":"4","lead_id":null}]"#.utf8))
        if idPage?.ids != ["a"] || idPage?.rows != 4 {
            problems.append("leads-ids: expected {a}/4 rows (rows counts EVERY row so paging "
                + "advances), got \(String(describing: idPage))")
        }
        // The keyset cursor is the LAST ROW's own id — including when that row's
        // lead_id is null. Advancing by anything else re-requests the same page
        // forever, or (with offset) skips rows whenever lead_id isn't unique, which
        // is exactly the shape of the `replies` table.
        if idPage?.cursor != "4" {
            problems.append("leads-ids: cursor must be the last row's id even when its lead_id is "
                + "null (got \(idPage?.cursor ?? "nil"))")
        }
        if LeadsRepository.leadIDs(Data("[]".utf8))?.rows != 0 {
            problems.append("leads-ids: [] must parse as an EMPTY page, not a failure")
        }
        if LeadsRepository.leadIDs(Data("[]".utf8))?.cursor != nil {
            problems.append("leads-ids: an empty page must not produce a cursor")
        }

        // Display ordering is applied AFTER the keyset walk (which is ordered by id,
        // not by date): newest first, undated rows last, ties broken by id so the
        // order is total — a list titled by recency must not lead with rows that
        // have no date at all.
        let ordered = LeadsRepository.newestFirst([
            LeadRow(id: "b", companyName: nil, firstName: nil, industry: nil, leadSource: nil,
                    city: nil, state: nil, createdAt: "2026-07-01T00:00:00+00:00"),
            LeadRow(id: "undated", companyName: nil, firstName: nil, industry: nil, leadSource: nil,
                    city: nil, state: nil, createdAt: nil),
            LeadRow(id: "c", companyName: nil, firstName: nil, industry: nil, leadSource: nil,
                    city: nil, state: nil, createdAt: "2026-07-20T00:00:00+00:00"),
            LeadRow(id: "a", companyName: nil, firstName: nil, industry: nil, leadSource: nil,
                    city: nil, state: nil, createdAt: "2026-07-20T00:00:00+00:00"),
        ])
        if ordered.map(\.id) != ["c", "a", "b", "undated"] {
            problems.append("leads-order: newest first, ties by id desc, undated last "
                + "(got \(ordered.map(\.id)))")
        }

        // Completeness is judged on DISTINCT ids. A walk that re-read rows would
        // otherwise satisfy `rows >= total` BY the duplication — the snapshot would
        // claim to be the whole book precisely when it had dropped rows.
        let dupRow = LeadRow(id: "dup", companyName: nil, firstName: nil, industry: nil,
                             leadSource: nil, city: nil, state: nil, createdAt: nil)
        let duplicated = LeadsRepository.compose(
            leads: [dupRow, dupRow, dupRow], totalCount: 3, leadsComplete: true)
        if duplicated.leadsComplete {
            problems.append("leads-compose: duplicated rows must NOT satisfy the completeness test")
        }

        // An RLS blackout returns 200 `[]`, not an error. Zero rows must therefore
        // read as "unreadable", never as "complete and empty" — `0 >= 0` used to
        // satisfy the completeness test and render a clean, freshly-stamped zero.
        let blackout = LeadsRepository.compose(leads: [], totalCount: 0, leadsComplete: true)
        if blackout.leadsComplete || !blackout.partial {
            problems.append("leads-compose: an empty read must fail CLOSED (200 [] is what a "
                + "revoked RLS policy returns), got complete=\(blackout.leadsComplete)")
        }
        if !blackout.degradedReads.contains(where: { $0.contains("reader grant") }) {
            problems.append("leads-compose: an empty read must name itself (got \(blackout.degradedReads))")
        }

        // The sent-events page parser: the PRODUCER half of the flat-zero-trend
        // CRITICAL. Pinning only `compose`'s handling of a hand-built `ok: false`
        // left a mutation alive — flipping this page's failure return to `true`
        // passed the entire suite.
        if LeadsRepository.sentEvents(Data("not json".utf8)) != nil {
            problems.append("sent-events: garbage body must be nil (failed page), not empty")
        }
        let sendPage = LeadsRepository.sentEvents(Data(
            #"[{"id":"1","lead_id":"a","sent_at":"2026-07-20T00:00:00+00:00"},{"id":"2","lead_id":null,"sent_at":null}]"#.utf8))
        if sendPage?.events.count != 1 || sendPage?.rows != 2 || sendPage?.cursor != "2" {
            problems.append("sent-events: expected 1 event / 2 rows / cursor 2, got "
                + "\(String(describing: sendPage.map { ($0.events.count, $0.rows, $0.cursor) }))")
        }
        if LeadsRepository.sentEvents(Data("[]".utf8))?.rows != 0 {
            problems.append("sent-events: [] must parse as an empty page")
        }
        // The cursor accepts a numeric id too: these walks are generic over `table`,
        // and a bigserial PK would otherwise stop the walk after one page with no
        // diagnostic — reported as a degraded read forever.
        if LeadsRepository.cursor(from: ["id": 42]) != "42" {
            problems.append("cursor: a numeric id must be usable as a keyset cursor")
        }
        if LeadsRepository.cursor(from: ["id": ""]) != nil {
            problems.append("cursor: a blank id must not be used as a cursor")
        }

        // A failed sent-events read must degrade, not render as a book nobody emailed.
        let sendsFailed = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            messaged: ([], ok: false))
        if !sendsFailed.partial || !sendsFailed.degradedReads.contains("outreach history") {
            problems.append("leads-compose: a failed sent-events read must mark partial and name itself "
                + "(got \(sendsFailed.degradedReads))")
        }

        return problems
    }

    /// The `--demo` book exists to be screenshotted and shown to strangers, so
    /// its contacts must stay provably fictional (reserved `.example` domains,
    /// 555-01xx phones). Every row must open a dossier (a dead click in a demo
    /// is a broken demo), the funnel must show every stage, and some fields must
    /// be blank, because a book with no gaps doesn't look real.
    private static func demoBookChecks() -> [String] {
        var problems: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let book = DemoBook.inputs(now: now)
        if book.leads.count != DemoBook.count {
            problems.append("demo: book has \(book.leads.count) rows, expected \(DemoBook.count)")
        }
        if Set(book.leads.map(\.id)).count != book.leads.count {
            problems.append("demo: duplicate lead ids")
        }
        if Set(book.leads.compactMap(\.companyName)).count != book.leads.count {
            problems.append("demo: duplicate company names")
        }
        if DemoBook.inputs(now: now).leads.map(\.email) != book.leads.map(\.email) {
            problems.append("demo: book is not deterministic")
        }
        var stages = Set<String>()
        let emailed = Set(book.messagedSends.map(\.leadID))
        for row in book.leads {
            stages.insert(LeadFacets.stage(lead: row, emailed: emailed.contains(row.id),
                                           replied: book.repliedLeadIDs.contains(row.id)))
            guard let p = DemoBook.profile(for: row.id, now: now) else {
                problems.append("demo: \(row.id) opens no dossier"); continue
            }
            if let e = p.lead.email, !e.hasSuffix(".example") {
                problems.append("demo: \(row.id) email \(e) is not on a reserved domain")
            }
            if let w = p.lead.website, !w.contains(".example") {
                problems.append("demo: \(row.id) website \(w) is not on a reserved domain")
            }
            if let ph = p.lead.phone, !ph.contains(") 555-01") {
                problems.append("demo: \(row.id) phone \(ph) is outside the 555-01xx block")
            }
            if row.statusRowMissing == true {
                problems.append("demo: \(row.id) carries the broken-invariant flag")
            }
            for send in book.messagedSends where send.leadID == row.id {
                if let at = DateParse.iso(send.sentAt), at > now {
                    problems.append("demo: \(row.id) has a send in the future")
                }
            }
        }
        for stage in ["Scraped", "Researched", "Personalized", "Campaigned", "Replied"]
            where !stages.contains(stage) {
            problems.append("demo: no lead at stage \(stage)")
        }
        let partial: [(String, (LeadRow) -> Bool)] = [
            ("industry", { $0.industry == nil }), ("first name", { $0.firstName == nil }),
            ("email", { $0.email == nil }), ("city/state", { $0.city == nil }),
        ]
        for (field, blank) in partial where !book.leads.contains(where: blank) {
            problems.append("demo: no row leaves \(field) blank")
        }
        let profiles = book.leads.compactMap { DemoBook.profile(for: $0.id, now: now) }
        let profileBlanks: [(String, (ProfileInputs) -> Bool)] = [
            ("phone", { $0.lead.phone == nil }), ("website", { $0.lead.website == nil }),
            ("research", { $0.enrichment == nil }),
            ("personalization", { $0.enrichment?.personalizedOpener == nil }),
        ]
        for (field, blank) in profileBlanks where !profiles.contains(where: blank) {
            problems.append("demo: no dossier leaves \(field) blank")
        }
        if profiles.contains(where: { $0.interactions.isEmpty }) {
            problems.append("demo: a dossier opens to an empty timeline")
        }
        if DemoBook.profile(for: "fixture-0001", now: now) != nil {
            problems.append("demo: a non-demo id resolved to a dossier")
        }
        if DemoBook.pinsDirectory() == PinsStore.defaultDirectory() {
            problems.append("demo: pins would share the real pin file")
        }
        return problems
    }

    /// Exercises the pins store (P5): toggle semantics, file round-trip in a
    /// throwaway temp dir, and corrupt-file tolerance (modeled on the old
    /// LayoutCache selftest block).
    private static func pinsChecks() -> [String] {
        var problems: [String] = []
        let a = LeadRef(id: "A", companyName: "Acme", email: nil)
        let b = LeadRef(id: "B", companyName: nil, email: "b@x.com")

        // Toggle: pin → newest-first; re-pin same id → unpin; other pin untouched.
        var pins = PinsStore.toggled([], with: a)
        pins = PinsStore.toggled(pins, with: b)
        if pins.map(\.id) != ["B", "A"] {
            problems.append("pins: toggle must prepend newest (got \(pins.map(\.id)))")
        }
        pins = PinsStore.toggled(pins, with: a)
        if pins.map(\.id) != ["B"] {
            problems.append("pins: re-toggle must unpin (got \(pins.map(\.id)))")
        }

        // Round-trip in a temp dir.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CECDashboardPinsSelfTest-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if !PinsStore.save([a, b], to: tmp) {
            problems.append("pins: save to temp dir failed")
        }
        let loaded = PinsStore.load(from: tmp)
        if loaded.map(\.id) != ["A", "B"] || loaded.first?.companyName != "Acme" {
            problems.append("pins: round-trip lost data (got \(loaded.map(\.id)))")
        }

        // Corrupt file → empty, never a crash; absent dir → empty.
        try? Data("not json".utf8).write(
            to: tmp.appendingPathComponent(PinsStore.filename))
        if !PinsStore.load(from: tmp).isEmpty {
            problems.append("pins: corrupt file must load as empty")
        }
        if !PinsStore.load(from: tmp.appendingPathComponent("nope")).isEmpty {
            problems.append("pins: absent dir must load as empty")
        }
        return problems
    }

    /// Exercises the profile compose seam (P3): timeline chronology, sentiment/
    /// intent from the LATEST inbound row's metadata, partial semantics, and
    /// the empty-timeline path.
    private static func profileComposeChecks() -> [String] {
        var problems: [String] = []
        let lead = LeadDetailRow(id: "L1", email: "a@b.c", firstName: "Ana",
                                 lastName: "Diaz", fullName: nil, companyName: "Acme",
                                 jobTitle: nil, companyDescription: nil, location: nil,
                                 city: nil, state: nil, phone: nil, website: nil,
                                 industry: nil)
        func interaction(_ at: String?, direction: String,
                         sentiment: String? = nil) -> LeadInteractionRow {
            LeadInteractionRow(
                id: nil, interactionType: "email", direction: direction, subject: "s",
                summary: nil, transcript: nil,
                metadata: sentiment.map { .object(["sentiment": .string($0),
                                                   "intent": .string("question")]) },
                source: nil, interactionAt: at)
        }

        // Sentiment comes from the LATEST inbound row; outbound rows and older
        // inbound sentiments are ignored. Out-of-order input gets re-sorted.
        let composed = ProfileRepository.compose(
            lead: lead,
            enrichment: nil,
            interactions: ([
                interaction("2026-07-02T10:00:00+00:00", direction: "inbound", sentiment: "negative"),
                interaction("2026-07-01T10:00:00+00:00", direction: "outbound"),
                interaction("2026-07-03T10:00:00+00:00", direction: "inbound", sentiment: "positive"),
                interaction("2026-07-04T10:00:00+00:00", direction: "outbound"),
            ], ok: true))
        if composed.sentiment != "positive" || composed.intent != "question" {
            problems.append("profile: sentiment must come from the LATEST inbound row "
                + "(got \(String(describing: composed.sentiment)))")
        }
        if composed.interactions.map(\.interactionAt) !=
            ["2026-07-01T10:00:00+00:00", "2026-07-02T10:00:00+00:00",
             "2026-07-03T10:00:00+00:00", "2026-07-04T10:00:00+00:00"] {
            problems.append("profile: timeline must be chronological")
        }
        if composed.partial { problems.append("profile: ok reads must not mark partial") }
        if composed.lead.displayName != "Ana Diaz" {
            problems.append("profile: displayName should join first+last (got \(composed.lead.displayName))")
        }

        // A missing generated row is a FACT, not a failure: no partial banner, and
        // the Personalization card suppresses via nil. Empty timeline never crashes.
        let noGenerated = ProfileRepository.compose(
            lead: lead, enrichment: nil, interactions: ([], ok: true))
        if noGenerated.partial { problems.append("profile: a lead with no generated row is not a partial dossier") }
        if noGenerated.sentiment != nil { problems.append("profile: empty timeline must yield nil sentiment") }
        let failedTimeline = ProfileRepository.compose(
            lead: lead, enrichment: nil, interactions: ([], ok: false))
        if !failedTimeline.interactionsFailed || !failedTimeline.partial {
            problems.append("profile: failed interactions read must set interactionsFailed + partial")
        }
        // The CORRUPT-generated flag is a fail-closed signal on the same axis
        // (delta round 3: the `|| enrichmentCorrupt` term was deletable under
        // a green suite — the exact shape the round-2 blocker closed, one
        // file over).
        let corruptGenerated = ProfileRepository.compose(
            lead: lead, enrichment: nil, interactions: ([], ok: true),
            enrichmentCorrupt: true)
        if !corruptGenerated.enrichmentCorrupt || !corruptGenerated.partial {
            problems.append("profile: a generated half that failed to DECODE must set "
                + "enrichmentCorrupt + partial — corruption must not render identically "
                + "to a lead that was never enriched")
        }
        // The all-NULL generated half (the LEFT JOIN's shape for an unenriched
        // lead) must classify as empty so the repository synthesizes nil — an
        // "enrichment" of nils would render an empty Personalization card.
        let blank = LeadEnrichmentRow(
            casualizedFirstName: nil, casualizedCompanyName: nil, casualizedCityName: nil,
            personalizationProject: nil, personalizationDetail: nil,
            personalizedOpener: nil, personalizedOffer: nil, research: nil,
            casualizedShape: nil)
        if !blank.isEmpty { problems.append("profile: an all-nil generated row must read as empty") }
        let oneField = LeadEnrichmentRow(
            casualizedFirstName: nil, casualizedCompanyName: nil, casualizedCityName: nil,
            personalizationProject: nil, personalizationDetail: nil,
            personalizedOpener: "hi", personalizedOffer: nil, research: nil,
            casualizedShape: nil)
        if oneField.isEmpty { problems.append("profile: any populated generated field must defeat isEmpty") }

        // PRODUCTION SHAPE (QA live finding): metadata jsonb is DOUBLE-ENCODED —
        // a JSON string, not an object. meta() must decode it or the sentiment
        // badge is dead against every real lead.
        let doubleEncoded = ProfileRepository.compose(
            lead: lead, enrichment: nil,
            interactions: ([LeadInteractionRow(
                id: nil, interactionType: "email", direction: "inbound", subject: nil,
                summary: nil, transcript: nil,
                metadata: .string(#"{"sentiment": "positive", "intent": "interested"}"#),
                source: nil, interactionAt: "2026-07-01T10:00:00+00:00")], ok: true))
        if doubleEncoded.sentiment != "positive" || doubleEncoded.intent != "interested" {
            problems.append("profile: double-encoded metadata must decode "
                + "(got \(String(describing: doubleEncoded.sentiment)))")
        }

        // Metadata that is garbage / non-object stays harmless.
        let noMeta = ProfileRepository.compose(
            lead: lead, enrichment: nil,
            interactions: ([LeadInteractionRow(
                id: nil, interactionType: "email", direction: "inbound", subject: nil,
                summary: nil, transcript: nil, metadata: .string("oops"),
                source: nil, interactionAt: "t")], ok: true))
        if noMeta.sentiment != nil {
            problems.append("profile: non-object metadata must not fabricate sentiment")
        }

        // Chronology is by PARSED date: mixed Z / +00:00 / fractional formats
        // and a nil timestamp must still order correctly (nil sinks first).
        let mixed = ProfileRepository.compose(
            lead: lead, enrichment: nil,
            interactions: ([
                interaction("2026-07-02T10:00:00Z", direction: "outbound"),
                interaction(nil, direction: "outbound"),
                interaction("2026-07-01T10:00:00.500+00:00", direction: "inbound", sentiment: "neutral"),
                interaction("2026-07-03T09:59:59+00:00", direction: "inbound", sentiment: "positive"),
            ], ok: true))
        if mixed.interactions.map(\.interactionAt) !=
            [nil, "2026-07-01T10:00:00.500+00:00", "2026-07-02T10:00:00Z",
             "2026-07-03T09:59:59+00:00"] {
            problems.append("profile: mixed-format timeline must sort by parsed date "
                + "(got \(mixed.interactions.map { $0.interactionAt ?? "nil" }))")
        }
        if mixed.sentiment != "positive" {
            problems.append("profile: mixed-format latest inbound wrong")
        }

        // Truncation: cap+1 rows → newest cap kept (OLDEST trimmed), flag set;
        // exactly cap rows → no flag (the +1 probe kills the false positive).
        let cap = ProfileRepository.interactionsCap
        func stamped(_ i: Int) -> LeadInteractionRow {
            interaction(String(format: "2026-01-01T%02d:%02d:%02d+00:00",
                               (i / 3600) % 24, (i / 60) % 60, i % 60),
                        direction: "outbound")
        }
        let overCap = ProfileRepository.compose(
            lead: lead, enrichment: nil,
            interactions: ((0...cap).map(stamped), ok: true))   // cap+1 rows
        if !overCap.interactionsTruncated || overCap.interactions.count != cap {
            problems.append("profile: cap+1 rows must trim to newest cap + flag truncated")
        }
        if overCap.interactions.first?.interactionAt == stamped(0).interactionAt {
            problems.append("profile: truncation must drop the OLDEST row, not the newest")
        }
        let atCap = ProfileRepository.compose(
            lead: lead, enrichment: nil,
            interactions: ((1...cap).map(stamped), ok: true))   // exactly cap
        if atCap.interactionsTruncated {
            problems.append("profile: exactly-cap rows must NOT flag truncated")
        }

        // The filter-char sanitizer keeps UUIDs intact and strips injection chars.
        if ProfileRepository.sanitized("abc-123") != "abc-123"
            || ProfileRepository.sanitized("x,y(z)\"") != "xyz" {
            problems.append("profile: id sanitizer wrong")
        }
        problems.append(contentsOf: profileCopyChecks())
        return problems
    }

    /// Click-to-copy: the fact list IS the clipboard payload, so pin the two
    /// properties a view edit could silently break — the copied string equals
    /// the rendered one, and no blank field becomes a dead copy target.
    private static func profileCopyChecks() -> [String] {
        var problems: [String] = []
        func detail(location: String? = nil, city: String? = nil, state: String? = nil,
                    jobTitle: String? = nil, bom: Bool = false) -> LeadDetailRow {
            LeadDetailRow(id: "C1",
                          email: bom ? "\u{FEFF}sales@acme.io" : "  sales@acme.io  ",
                          firstName: nil,
                          lastName: nil, fullName: nil, companyName: "Acme",
                          jobTitle: jobTitle, companyDescription: nil,
                          location: location, city: city, state: state,
                          phone: "(561) 320-2842", website: "https://acme.io/",
                          industry: bom ? "Solar en\u{00AD}ergy" : "Solar energy system service")
        }

        // FULLY POPULATED: pins the complete label set and order. Without this
        // the blank-drop fixture below would keep passing if a field were
        // DELETED from ProfileFacts — the dossier would silently lose a row.
        let allContact = ProfileFacts.contact(detail(city: "Stuart", state: "Florida",
                                                     jobTitle: "Owner"))
        if allContact.map(\.label)
            != ["Title", "Industry", "Location", "Phone", "Website", "Email"] {
            problems.append("copy: contact fact set/order changed "
                + "(\(allContact.map(\.label)))")
        }

        // Blank / whitespace-only fields are dropped; the rest keep display order.
        let facts = ProfileFacts.contact(detail(city: "Stuart", state: "Florida",
                                                jobTitle: "   "))
        if facts.map(\.label) != ["Industry", "Location", "Phone", "Website", "Email"] {
            problems.append("copy: contact facts wrong or a blank field leaked "
                + "(\(facts.map(\.label)))")
        }
        // Copied == rendered: the value is the trimmed source string, never a
        // reformatted display form (a prettified phone/URL would poison paste).
        let byLabel = Dictionary(uniqueKeysWithValues: facts.map { ($0.label, $0.value) })
        for (label, expected) in ["Email": "sales@acme.io",
                                  "Phone": "(561) 320-2842",
                                  "Website": "https://acme.io/",
                                  "Industry": "Solar energy system service",
                                  "Location": "Stuart, Florida"] {
            if byLabel[label] != expected {
                problems.append("copy: \(label) payload must be the rendered value "
                    + "(got \(byLabel[label] ?? "nil"), want \(expected))")
            }
        }
        // Location: explicit column wins; a lone city/state still composes; all
        // three blank drops the row entirely.
        if ProfileFacts.location(detail(location: "Stuart, FL", city: "X", state: "Y"))
            != "Stuart, FL" {
            problems.append("copy: explicit location column must win over city/state")
        }
        if ProfileFacts.location(detail(city: "Stuart")) != "Stuart" {
            problems.append("copy: a lone city must still compose a location")
        }
        if ProfileFacts.contact(detail()).contains(where: { $0.label == "Location" }) {
            problems.append("copy: no location parts must drop the row, not render blank")
        }

        // Personalization grid: same blank-drop rule, same verbatim payload.
        // (Source/Status/Tier left with the lead_enrichment table — 7.2.)
        let enrichment = LeadEnrichmentRow(
            casualizedFirstName: " Ana ", casualizedCompanyName: "", casualizedCityName: nil,
            personalizationProject: "roof retrofits", personalizationDetail: nil,
            personalizedOpener: "opener", personalizedOffer: nil,
            research: nil, casualizedShape: "object")
        let pFacts = ProfileFacts.personalization(enrichment)
        if pFacts.map(\.label) != ["Casual name", "Project ref"] {
            problems.append("copy: personalization facts wrong or a blank leaked "
                + "(\(pFacts.map(\.label)))")
        }
        if pFacts.first?.value != "Ana" {
            problems.append("copy: padded values must be trimmed identically for "
                + "display and clipboard")
        }

        // A BOM must not survive into a fact's payload (full sanitizer matrix
        // lives in sanitizerChecks; this pins that facts route THROUGH it).
        let hostileFacts = Dictionary(uniqueKeysWithValues:
            ProfileFacts.contact(detail(bom: true)).map { ($0.label, $0.value) })
        if hostileFacts["Email"] != "sales@acme.io"
            || hostileFacts["Industry"] != "Solar energy" {
            problems.append("copy: fact values must be sanitized, not raw "
                + "(got \(hostileFacts["Email"]?.debugDescription ?? "nil"))")
        }

        // The still-render demo seam must only ever force the named field.
        let demo = CopyDemo(hoverLabel: "Industry", copiedLabel: "Email")
        if demo.state(for: "Industry") != .hover || demo.state(for: "Email") != .copied
            || demo.state(for: "Phone") != .none {
            problems.append("copy: CopyDemo must force state only on the named fields")
        }
        if CopyDemo().state(for: "Email") != .none {
            problems.append("copy: an empty CopyDemo must force nothing (live default)")
        }
        // An unset label is "", which must match nothing rather than colliding.
        if CopyDemo(hoverLabel: "", copiedLabel: "").state(for: "") != .none {
            problems.append("copy: an empty demo label must match no field")
        }
        // The harness's demo labels must name REAL facts, or --screenshot
        // profile-copy silently renders identically to profile and stops
        // proving the affordance exists.
        let fixtureLabels = Set(ProfileFacts.contact(LeadProfileFixture.inputs.lead)
            .map(\.label))
        for label in [LeadProfileFixture.copyDemo.hoverLabel,
                      LeadProfileFixture.copyDemo.copiedLabel].compactMap({ $0 })
            where !fixtureLabels.contains(label) {
            problems.append("copy: harness demo label '\(label)' names no fixture "
                + "fact — profile-copy would render identically to profile")
        }

        // The pasteboard round-trip itself, and that a write reports success.
        // Save + restore the user's clipboard around the probe — a diagnostic
        // must not eat whatever the operator had copied (swift-semantics note).
        let saved = NSPasteboard.general.string(forType: .string)
        if !Pasteboard.copy("selftest-probe")
            || NSPasteboard.general.string(forType: .string) != "selftest-probe" {
            problems.append("copy: pasteboard round-trip failed")
        }
        if let saved { _ = Pasteboard.copy(saved) }
        problems.append(contentsOf: sanitizerChecks())
        problems.append(contentsOf: previewRenderChecks())
        return problems
    }

    /// The sanitizer strips what renders as nothing and KEEPS what carries
    /// meaning. Both halves are load-bearing: too little and invisible scrapes
    /// poison the clipboard, too much and emoji/Persian/Indic text is corrupted.
    private static func sanitizerChecks() -> [String] {
        var problems: [String] = []
        func check(_ name: String, _ input: String, _ expected: String?) {
            let got = ProfileFacts.inlineValue(input)
            if got != expected {
                problems.append("copy/sanitize \(name): got \(got?.debugDescription ?? "nil") "
                    + "want \(expected?.debugDescription ?? "nil")")
            }
        }
        // Stripped — invisible and meaningless.
        check("bom", "\u{FEFF}sales@acme.io", "sales@acme.io")
        check("soft-hyphen", "Solar en\u{00AD}ergy", "Solar energy")
        check("zero-width-space", "a\u{200B}b", "ab")
        check("bidi-override", "\u{202E}moc.evil\u{202C}@x.com", "moc.evil@x.com")
        check("lrm", "x\u{200E}y", "xy")
        check("word-joiner", "a\u{2060}b", "ab")
        // Collapsed — a one-line field must paste as one line, and a tab is a
        // word boundary that must never be deleted outright.
        check("newline", "https://acme.io/\nrm -rf ~", "https://acme.io/ rm -rf ~")
        check("tab", "Hi\tthere", "Hi there")
        check("line-separator", "a\u{2028}b", "a b")
        // CRLF is ONE break: sweeping CR in with tab double-spaced every line of
        // Windows/CSV-sourced text (caught in delta review round 2).
        check("crlf", "a\r\nb", "a b")
        check("lone-cr", "a\rb", "a b")
        // The "invisible character" generators' favourites.
        check("hangul-filler", "Acme\u{3164}Solar", "AcmeSolar")
        check("arabic-letter-mark", "x\u{061C}y", "xy")
        // PRESERVED — these carry meaning; stripping them corrupts real values.
        check("emoji-zwj", "Team 👨‍👩‍👧‍👦 Solar", "Team 👨‍👩‍👧‍👦 Solar")
        check("emoji-vs16", "Solar ⚡️ Pros", "Solar ⚡️ Pros")
        check("persian-zwnj", "می‌روم", "می‌روم")
        check("accents-cjk", "Café 太陽光 Solar", "Café 太陽光 Solar")
        // Block prose keeps line structure but loses the invisibles, and its tab
        // handling must match the inline path (they drifted apart once).
        if ProfileFacts.blockValue("Line one.\n\u{200B}Line two.") != "Line one.\nLine two." {
            problems.append("copy/sanitize block: must keep newlines and drop invisibles")
        }
        if ProfileFacts.blockValue("Hi\tthere") != "Hi there" {
            problems.append("copy/sanitize block: a tab must collapse, not vanish")
        }
        if ProfileFacts.blockValue("a\r\nb") != "a\nb" {
            problems.append("copy/sanitize block: CRLF must be ONE newline, not a "
                + "newline plus a stray space on every line")
        }
        // Mongolian free variation selectors are glyph selectors, same category
        // as FE00-FE0F which we preserve — keep the rule internally consistent.
        if ProfileFacts.inlineValue("\u{1820}\u{180B}") != "\u{1820}\u{180B}" {
            problems.append("copy/sanitize: Mongolian variation selectors must be "
                + "preserved like the other variation selectors")
        }
        if ProfileFacts.blockValue("Team 👨‍👩‍👧‍👦") != "Team 👨‍👩‍👧‍👦" {
            problems.append("copy/sanitize block: emoji sequences must survive the opener")
        }
        // An all-invisible value is a blank row with a live copy target.
        if ProfileFacts.inlineValue("\u{200B}\u{FEFF}\u{00AD}") != nil {
            problems.append("copy/sanitize: an all-invisible value must drop entirely")
        }
        // Labels are the demo key AND half of each row's identity, across BOTH
        // grids and the prose blocks — uniqueness must hold over the union.
        let lead = LeadProfileFixture.inputs.lead
        var allLabels = ProfileFacts.contact(lead).map(\.label)
        if let e = LeadProfileFixture.inputs.enrichment {
            allLabels += ProfileFacts.personalization(e).map(\.label)
        }
        allLabels += ["Opener", "Offer"]
        if Set(allLabels).count != allLabels.count {
            problems.append("copy: profile labels must be unique across both grids "
                + "and the prose blocks (\(allLabels))")
        }
        return problems
    }

    /// Every registered preview must render without SwiftUI's "unsupported view"
    /// placeholder. An AppKit-backed child silently destroys the still it appears
    /// in — `--screenshot` still exits 0 — so this is the only thing that notices.
    private static func previewRenderChecks() -> [String] {
        var problems: [String] = []
        // Positive control FIRST: prove the detector can still see a placeholder
        // before trusting it to report their absence. "0 hits" must mean clean,
        // not blind (a future macOS could change the placeholder shade).
        switch PreviewHarness.detectorControlPixels() {
        case nil:
            problems.append("preview: placeholder detector control failed to render")
        case let hits? where hits <= PreviewHarness.placeholderTolerance:
            problems.append("preview: placeholder detector is BLIND — an ungated "
                + "NSViewRepresentable scored only \(hits); the placeholder colour "
                + "may have changed, so every clean result below is meaningless")
        default:
            break
        }
        // A canvases key that names no view falls back to the 1440×1000 tab canvas,
        // so the icon would render non-square and only surface as an actool
        // complaint far from the cause.
        for key in PreviewRegistry.canvases.keys.sorted() where PreviewRegistry.views[key] == nil {
            problems.append("preview: canvases key '\(key)' is not a registered view")
        }
        for name in PreviewRegistry.views.keys.sorted() {
            guard let hits = PreviewHarness.placeholderPixels(in: name) else {
                problems.append("preview: '\(name)' failed to render")
                continue
            }
            if hits > PreviewHarness.placeholderTolerance {
                problems.append("preview: '\(name)' renders \(hits) placeholder-yellow "
                    + "pixels — an AppKit-backed view is not gated on \\.isStaticRender")
            }
        }
        return problems
    }

}
