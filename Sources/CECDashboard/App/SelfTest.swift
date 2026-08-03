import AppKit
import Foundation

/// Headless verification of the decode contract (run with `--selftest`).
/// Exercises the decode contract plus every pure builder/compose seam.
/// Main-actor: `--selftest` runs pre-boot from `App.init()` on the main thread,
/// and the copy checks touch AppKit (`NSPasteboard`).
@MainActor
enum SelfTest {
    static func run() -> Never {
        guard let dash = MockData.dashboard else {
            FileHandle.standardError.write(Data("SELFTEST FAIL: mock dashboard failed to decode\n".utf8))
            exit(1)
        }

        var problems: [String] = []

        // Every layout widget must have matching data and a rect per breakpoint.
        let bps = Set(dash.layout.breakpoints.keys)
        for widget in dash.layout.widgets {
            if dash.widgets[widget.id] == nil {
                problems.append("widget '\(widget.id)' has no data")
            }
            let missing = bps.subtracting(widget.layouts.keys)
            if !missing.isEmpty {
                problems.append("widget '\(widget.id)' missing layouts: \(missing.sorted())")
            }
        }

        // All four widget kinds should be represented in the M0 sample.
        let kinds = Set(dash.widgets.values.map { kindName($0) })
        for expected in ["kpi", "chart", "table", "status-board"] where !kinds.contains(expected) {
            problems.append("missing widget kind: \(expected)")
        }

        // Resilience: one malformed widget must be dropped, not blank the dashboard.
        let layoutJSON = """
        { "breakpoints": {"lg":1200}, "cols": {"lg":12}, "rowHeight": 80,
          "widgets": [ {"id":"a","type":"kpi","layouts":{"lg":{"x":0,"y":0,"w":3,"h":2}}} ] }
        """
        let mixedWidgets = """
        { "a": {"type":"kpi","title":"Good","value":10},
          "b": {"type":"not-a-real-type","title":"Bad"} }
        """
        if let partial = Dashboard.decode(layoutJSON: layoutJSON, widgetsJSON: mixedWidgets) {
            if partial.widgets["a"] == nil { problems.append("resilience: good widget 'a' was dropped") }
            if partial.widgets["b"] != nil { problems.append("resilience: bad widget 'b' was not dropped") }
        } else {
            problems.append("resilience: one bad widget blanked the whole dashboard")
        }

        // Binding: DashboardBuilder turns lead rows into the widget contract.
        let sampleLeads: [LeadRow] = [
            LeadRow(id: "1", companyName: "Acme", firstName: "A", industry: "Auto",
                    leadSource: "gmaps-leads", city: "Tampa", state: "FL", createdAt: "2026-06-10T12:00:00+00:00",
                    enrichmentStage: "personalized"),
            LeadRow(id: "2", companyName: "Globex", firstName: "B", industry: "Biotech",
                    leadSource: "sales-nav", city: "Austin", state: "TX", createdAt: "2026-06-12T12:00:00.500+00:00",
                    enrichmentStage: "scraped"),
            LeadRow(id: "3", companyName: "Initech", firstName: "C", industry: "Tech",
                    leadSource: "gmaps-leads", city: nil, state: nil, createdAt: nil),
        ]
        let built = DashboardBuilder.build(DashboardInputs(leads: sampleLeads, totalCount: 720))
        // Deterministic plan: tier/sentiment boards are skipped when their
        // supplementary counts are empty (empty board = noise); recent-leads is
        // the native list below the grid now (P3), not a widget; total-leads is
        // the toolbar subtitle now (i-9f08), not a KPI widget.
        if Set(built.layout.widgets.map { $0.id })
            != ["by-source", "by-industry", "by-status", "added-weekly"] {
            problems.append("builder: unexpected widget ids (\(built.layout.widgets.map { $0.id }.sorted()))")
        }
        problems.append(contentsOf: validateGrid(built.layout, label: "leads-build"))
        // by-status buckets enrichment_stage capitalized, nil → "Unknown", counts sum to the window.
        if case .statusBoard(let board)? = built.widgets["by-status"] {
            let labels = Set(board.groups.map { $0.label })
            if labels != ["Personalized", "Scraped", "Unknown"] {
                problems.append("builder: by-status labels unexpected (\(labels.sorted()))")
            }
            if board.groups.reduce(0, { $0 + $1.count }) != sampleLeads.count {
                problems.append("builder: by-status counts != lead count")
            }
        } else {
            problems.append("builder: by-status is not a status board")
        }
        if case .statusBoard(let board)? = built.widgets["by-source"] {
            let summed = board.groups.reduce(0) { $0 + $1.count }
            if summed != sampleLeads.count { problems.append("builder: source counts (\(summed)) != lead count") }
        } else {
            problems.append("builder: by-source is not a status board")
        }
        // The row with nil createdAt must not crash the weekly chart; ≤2 weeks present.
        if case .chart(let chart)? = built.widgets["added-weekly"], chart.points.count > 8 {
            problems.append("builder: chart exceeded 8 buckets")
        }

        // Zero-fill: leads 3 weeks apart must produce 4 contiguous weekly points (gaps = 0),
        // not 2 collapsed points.
        let gapLeads: [LeadRow] = [
            LeadRow(id: "g1", companyName: "X", firstName: nil, industry: nil,
                    leadSource: "a", city: nil, state: nil, createdAt: "2026-05-04T00:00:00+00:00"),
            LeadRow(id: "g2", companyName: "Y", firstName: nil, industry: nil,
                    leadSource: "a", city: nil, state: nil, createdAt: "2026-05-25T00:00:00+00:00"),
        ]
        let gapBuilt = DashboardBuilder.build(DashboardInputs(leads: gapLeads, totalCount: 2))
        if case .chart(let chart)? = gapBuilt.widgets["added-weekly"] {
            let zeros = chart.points.filter { $0.y == 0 }.count
            if chart.points.count != 4 || zeros != 2 {
                problems.append("builder: zero-fill expected 4 points/2 zeros, got \(chart.points.count) points/\(zeros) zeros")
            }
        } else {
            problems.append("builder: gap chart is not a chart")
        }

        // Packer: any plan must expand to a grid with NO overlaps and every
        // rect in-bounds, at every breakpoint — the "can't make a broken grid" guarantee.
        let plan = LayoutPlan(widgets: [
            PlannedWidget(type: .kpi, bind: "total-leads", size: .small, priority: 1),
            PlannedWidget(type: .kpi, bind: "enriched", size: .small, priority: 2),
            PlannedWidget(type: .statusBoard, bind: "by-source", size: .medium, priority: 3),
            PlannedWidget(type: .chart, bind: "added-weekly", size: .large, priority: 4),
            PlannedWidget(type: .table, bind: "recent-leads", size: .full, priority: 5),
            PlannedWidget(type: .kpi, bind: "total-leads", size: .large, priority: 6), // dup bind
        ])
        let packed = Packer.pack(plan)
        problems.append(contentsOf: validateGrid(packed, label: "packer"))
        if packed.widgets.count != 5 {
            problems.append("packer: expected 5 widgets after dedupe, got \(packed.widgets.count)")
        }
        // A full-width widget must occupy its own row width at lg (span == cols).
        if let table = packed.widgets.first(where: { $0.id == "recent-leads" }),
           let r = table.layouts["lg"], r.w != 12 {
            problems.append("packer: full-size widget should span all 12 lg cols, got \(r.w)")
        }

        // availableBinds must match exactly what widgetData produces (drift guard).
        let dataKeys = Set(DashboardBuilder.widgetData(DashboardInputs(leads: sampleLeads, totalCount: 720)).keys)
        if dataKeys != DashboardBuilder.availableBinds {
            problems.append("builder: availableBinds \(DashboardBuilder.availableBinds) != widgetData keys \(dataKeys)")
        }

        // M3b: tier/sentiment boards from supplementary counts (DashboardInputs).
        let m3bInputs = DashboardInputs(
            leads: sampleLeads, totalCount: 720,
            tierCounts: ["A": 50, "B": 30, "C": 20],
            sentimentCounts: ["positive": 12, "neutral": 5, "negative": 3]
        )
        let m3bData = DashboardBuilder.widgetData(m3bInputs)
        if case .statusBoard(let tier)? = m3bData["by-tier"] {
            if tier.groups.reduce(0, { $0 + $1.count }) != 100 { problems.append("m3b: tier counts != 100") }
        } else { problems.append("m3b: by-tier is not a status board") }
        if case .statusBoard(let sent)? = m3bData["sentiment-mix"] {
            if sent.groups.first?.label != "positive" { problems.append("m3b: sentiment not sorted (top should be positive)") }
        } else { problems.append("m3b: sentiment-mix is not a status board") }
        // Empty supplementary tables → empty board data AND the plan skips them.
        let emptyInputs = DashboardInputs(leads: sampleLeads, totalCount: 720)
        if case .statusBoard(let tier)? = DashboardBuilder.widgetData(emptyInputs)["by-tier"],
           !tier.groups.isEmpty { problems.append("m3b: empty tierCounts should yield an empty board") }
        let m3bBuilt = DashboardBuilder.build(m3bInputs)
        if !m3bBuilt.layout.widgets.contains(where: { $0.id == "by-tier" })
            || !m3bBuilt.layout.widgets.contains(where: { $0.id == "sentiment-mix" }) {
            problems.append("m3b: present tier/sentiment counts should be planned")
        }
        problems.append(contentsOf: validateGrid(m3bBuilt.layout, label: "leads-build-m3b"))

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

        // ── Healing backlog: BacklogRepository.compose (P6) ─────────────────────────
        problems.append(contentsOf: backlogComposeChecks())

        // ── Campaigns tab: CampaignsRepository.compose + CampaignBuilder ────────────
        // The compose path is pure (no I/O), so we exercise the join/binding edge cases
        // here rather than against the live DB.
        problems.append(contentsOf: campaignChecks())

        // ── Pipeline tab: PipelineRepository.compose + PipelineBuilder ──────────────
        problems.append(contentsOf: pipelineChecks())

        // ── Leads tab: live DashboardInputs → ABLeadsData mapping (pure/total) ──────
        problems.append(contentsOf: abLeadsMappingChecks())

        let summary = "widgets=\(dash.layout.widgets.count) data=\(dash.widgets.count) kinds=\(kinds.sorted())"
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

    /// The two-lead sample the mapping checks share.
    private static var abSampleLeads: [LeadRow] {
        [
            LeadRow(id: "a", companyName: "Acme", firstName: "Ada", industry: "Auto",
                    leadSource: "sales-nav", city: "Tampa", state: "FL",
                    createdAt: "2026-07-01T12:00:00+00:00", enrichmentStage: "campaigned"),
            LeadRow(id: "b", companyName: nil, firstName: nil, industry: nil,
                    leadSource: nil, city: nil, state: nil,
                    createdAt: "2026-07-08T12:00:00+00:00", enrichmentStage: "scraped"),
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
            personalizedLeadIDs: ["a"], repliedLeadIDs: ["a", "ghost"],
            messagedSends: sends)
        let d = ABLeadsData(inputs: inputs, now: now)

        if d.totals.scraped != 2 { problems.append("abmap: scraped must count the matching leads (got \(d.totals.scraped))") }
        if d.totals.emailed != 1 { problems.append("abmap: emailed must count campaigned leads (got \(d.totals.emailed))") }
        // "ghost" replied but is not in the lead book — the ratio is replied LEADS
        // over emailed LEADS, so a reply with no matching lead cannot inflate it.
        if d.totals.replies != 1 {
            problems.append("abmap: replies must intersect the shown leads, not count reply rows (got \(d.totals.replies))")
        }
        if abs(d.emailedOfScrapedPct - 50.0) > 0.001 { problems.append("abmap: emailedOfScrapedPct math (got \(d.emailedOfScrapedPct))") }
        if abs(d.repliesOfEmailedPct - 100.0) > 0.001 { problems.append("abmap: repliesOfEmailedPct math (got \(d.repliesOfEmailedPct))") }
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
        // The status panel counts the snapshot, so it moves with the filter.
        if d.byStatus.map(\.label).sorted() != ["Campaigned", "Scraped"] {
            problems.append("abmap: byStatus must roll up the shown leads (got \(d.byStatus.map(\.label)))")
        }
        // F4: an out-of-window outlier timestamp must not shift/blank the axis.
        let outlier = ABLeadsData(inputs: DashboardInputs(
            leads: [LeadRow(id: "x", companyName: "Old", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2001-01-01T00:00:00+00:00", enrichmentStage: "scraped")],
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
        if !empty.bySource.isEmpty || !empty.byStatus.isEmpty { problems.append("abmap: empty leads → empty breakdowns") }
        if empty.breakdownScopeNote != nil { problems.append("abmap: complete/empty data → no scope note") }

        // WINDOWED snapshot: ONE population, always. There is no "keep the exact
        // full-table totals while nothing is filtered" path — it existed once, and
        // because the snapshot fetch no longer issues per-stage HEAD reads it put a
        // whole-table `scraped` in the header beside a window-scoped `scraped` in the
        // hero, with a reply rate of 500%. Pins the mixed-population bug class:
        // every headline figure must be counted over the SAME rows.
        let windowedInputs = DashboardInputs(
            leads: leads, totalCount: 200, leadsComplete: false,
            statusCounts: ["campaigned": 80, "scraped": 120],   // present and IGNORED
            repliedLeadIDs: ["a", "z"], messagedSends: sends)
        let windowed = ABLeadsData(inputs: windowedInputs, now: now)
        if windowed.totals.scraped != 2 || windowed.totals.emailed != 1 || windowed.totals.replies != 1 {
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
        // CAMPAIGNED matching leads, so the numerator is a subset of the denominator
        // even when a lead replied while still at an earlier stage (a data-integrity
        // problem upstream that used to render as 200%).
        let earlyReply = ABLeadsData(inputs: DashboardInputs(
            leads: [LeadRow(id: "p", companyName: "P", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2026-07-20T12:00:00+00:00", enrichmentStage: "campaigned"),
                    LeadRow(id: "q", companyName: "Q", firstName: nil, industry: nil,
                            leadSource: nil, city: nil, state: nil,
                            createdAt: "2026-07-20T12:00:00+00:00", enrichmentStage: "personalized")],
            totalCount: 2, leadsComplete: true, repliedLeadIDs: ["p", "q"]), now: now)
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
        if vm.state.value?.filter.source != "sales-nav" {
            problems.append("vm: apply() must re-derive through the new filter")
        }
        if vm.state.value?.matchingCount == vm.state.value.map({ _ in 0 }) {
            problems.append("vm: filtered snapshot should still match some leads")
        }

        // Search: a term below the minimum dismisses the RESULTS and keeps the text.
        let search = LeadSearchModel()
        search.fixtureRows = vm.snapshotLeads
        search.query = "Harborline"
        search.submit()
        guard case .results(_, let hits) = search.state, !hits.isEmpty else {
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
                           apiKey: "stub", session: StubURLProtocol.session(handler))
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
            problems.append("walk: an unparseable send_queue page must report ok:false")
        }
        let ids = runAsyncValue { await badRepo.leadIDsResult(table: "replies", filter: nil,
                                                              pageSize: 2, maxPages: 3) }
        if ids?.ok != false {
            problems.append("walk: an unparseable lead_id page must report ok:false")
        }
        // An HTTP error is also a degraded read, not an empty one.
        let errRepo = LeadsRepository(client: client({ _ in .init(status: 401, body: "{}") }))
        let errIDs = runAsyncValue { await errRepo.leadIDsResult(table: "replies", filter: nil) }
        if errIDs?.ok != false || errIDs?.ids.isEmpty != true {
            problems.append("walk: a 401 must degrade, not return a confident empty set")
        }
        return problems
    }

    /// One stubbed `leads` row. Nonisolated so the stub's request handler — which
    /// runs off the main actor — can build pages.
    private nonisolated static func leadJSON(_ id: String,
                                             created: String = "2026-07-20T00:00:00+00:00") -> String {
        #"{"id":"\#(id)","company_name":"C\#(id)","created_at":"\#(created)","enrichment_stage":"scraped"}"#
    }

    /// Run an async throwing call to completion from the synchronous selftest.
    private static func runAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return box.value ?? .failure(CancellationError())
    }

    private static func runAsyncValue<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
        try? runAsync { await body() }.get()
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

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
    /// menus count against the other dimensions, and a degraded lane read disables
    /// the dimension instead of answering wrongly.
    private static func leadFilterChecks() -> [String] {
        var problems: [String] = []
        let now = abNow

        func lead(_ id: String, source: String, industry: String, state: String?,
                  location: String? = nil, stage: String, created: String) -> LeadRow {
            LeadRow(id: id, companyName: "C\(id)", firstName: nil, industry: industry,
                    leadSource: source, city: nil, state: state, createdAt: created,
                    enrichmentStage: stage, location: location)
        }
        // 4 leads: 2 Florida (one deep + campaigned + replied, one standard),
        // 1 Texas (from free-text location), 1 unpersonalized California.
        let leads = [
            lead("a", source: "gmaps-leads", industry: "Solar", state: "FL",
                 stage: "campaigned", created: "2026-07-20T12:00:00+00:00"),
            lead("b", source: "gmaps-leads", industry: "Solar", state: "Florida",
                 stage: "campaigned", created: "2026-07-20T12:00:00+00:00"),
            lead("c", source: "sales-nav", industry: "Biotech", state: nil,
                 location: "Austin, Texas, United States",
                 stage: "personalized", created: "2026-07-13T12:00:00+00:00"),
            lead("d", source: "sales-nav", industry: "Biotech", state: "CA",
                 stage: "scraped", created: "2026-07-06T12:00:00+00:00"),
        ]
        let inputs = DashboardInputs(
            leads: leads, totalCount: 4, leadsComplete: true,
            deepLaneLeadIDs: ["a"], personalizedLeadIDs: ["a", "b", "c"],
            repliedLeadIDs: ["a", "b"],
            messagedSends: [
                .init(leadID: "a", sentAt: "2026-07-21T09:00:00+00:00"),
                .init(leadID: "d", sentAt: "2026-07-21T09:00:00+00:00"),
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
        // Lead "d" was messaged but is filtered out — its send is not this view's trend.
        if florida.leadsMessagedWeekly.values.reduce(0, +) != 1 {
            problems.append("filter: the messaged trend must exclude sends to filtered-out leads "
                + "(got \(florida.leadsMessagedWeekly.values.reduce(0, +)))")
        }
        // EVERY panel counts the filtered set — asserted by TOTAL, not by row count.
        // QA's mutation run proved the earlier `.count` checks were blind: swapping
        // `byStatus`/`byRegion` to the unfiltered facets left the suite green, and
        // those are precisely the panels this feature added. A sum can't be fooled
        // by two categories collapsing to the same shape.
        for (name, items, expected) in [
            ("bySource", florida.bySource, 2), ("byIndustry", florida.byIndustry, 2),
            ("byRegion", florida.byRegion, 2), ("byStatus", florida.byStatus, 2),
        ] {
            let total = items.reduce(0) { $0 + $1.count }
            if total != expected {
                problems.append("filter: \(name) must total the FILTERED set (got \(total), want \(expected))")
            }
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
            problems.append("filter: hero 'emailed' must count only MATCHING campaigned leads "
                + "(got \(california.totals.emailed) over \(california.matchingCount) leads)")
        }
        if california.totals.replies != 0 {
            problems.append("filter: replies must narrow with the filter (got \(california.totals.replies))")
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

        // Degraded lane reads: the dimension is dropped rather than answered wrongly
        // (empty id sets would classify every lead "Not personalized").
        // Built through `compose`, not hand-assembled: a hand-built value encodes
        // what I THINK the repository produces, and the flags that drive this
        // behaviour (`partial`, `degradedReads`) are set there, not here.
        let degradedInputs = LeadsRepository.compose(
            leads: leads, totalCount: leads.count, leadsComplete: true,
            deep: ([], ok: false), personalized: ([], ok: false),
            replied: (inputs.repliedLeadIDs, ok: true),
            messaged: (inputs.messagedSends, ok: true))
        let degraded = ABLeadsData(inputs: degradedInputs, filter: LeadFilter(lane: .deep), now: now)
        if degraded.laneFilterAvailable {
            problems.append("filter: a failed lane read must disable the lane menu")
        }
        if degraded.effectiveFilter.lane != nil || degraded.matchingCount != 4 {
            problems.append("filter: a lane filter over degraded lane data must be dropped, not applied "
                + "(got \(degraded.matchingCount) leads)")
        }
        // …but the user's REQUESTED filter is preserved: the bar edits `filter`, so a
        // suppressed dimension is restored when the read recovers instead of being
        // silently written away on the next menu pick.
        if degraded.filter.lane != .deep {
            problems.append("filter: suppressing a dimension must not discard the user's selection")
        }
        // A degraded load names what is understated rather than showing a confident
        // zero — the flag alone rendered nowhere.
        if !degradedInputs.partial || degraded.degradedReads.isEmpty {
            problems.append("filter: a degraded load must carry named reads for the UI to surface")
        }

        // The list is capped, and says so through matchingCount ≠ rendered rows.
        let many = (0..<(ABLeadsData.listCap + 5)).map {
            lead("m\($0)", source: "gmaps-leads", industry: "Solar", state: "FL",
                 stage: "scraped", created: "2026-07-20T12:00:00+00:00")
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
                 stage: "scraped", created: "2026-07-20T12:00:00+00:00")
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
                            createdAt: "2026-07-20T12:00:00+00:00", enrichmentStage: "scraped")],
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
                         stage: "campaigned", created: "2026-07-06T12:00:00+00:00")],
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

        // Every supplementary read ok (even when empty) → NOT partial, NOT degraded.
        let clean = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            deep: (["a"], ok: true), personalized: (["a", "b"], ok: true),
            replied: ([], ok: true))
        if clean.partial || clean.lanesDegraded {
            problems.append("leads-compose: ok reads must not mark partial/degraded")
        }
        if clean.deepLaneLeadIDs != ["a"] || clean.personalizedLeadIDs != ["a", "b"] {
            problems.append("leads-compose: lane id sets not packaged through")
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

        // A failed LANE read → partial AND degraded (the lane menu disables itself).
        let laneFailed = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            deep: ([], ok: false), personalized: ([], ok: true), replied: ([], ok: true))
        if !laneFailed.partial || !laneFailed.lanesDegraded {
            problems.append("leads-compose: a failed lane read must mark partial AND degraded")
        }
        // A failed REPLIES read is partial but not lane-degraded — the reply figure
        // is understated, the lane classification is still sound.
        let repliesFailed = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            deep: ([], ok: true), personalized: ([], ok: true), replied: ([], ok: false))
        if !repliesFailed.partial || repliesFailed.lanesDegraded {
            problems.append("leads-compose: a failed replies read is partial, not lane-degraded")
        }

        // The widget/packer path still reads exact stage counts off DashboardInputs.
        let withStatus = DashboardInputs(
            leads: sampleLeads, totalCount: 720,
            statusCounts: ["scraped": 400, "personalized": 300, "unknown": 20])
        if case .statusBoard(let board)? = DashboardBuilder.widgetData(withStatus)["by-status"] {
            if board.title != "Leads by Status" {
                problems.append("leads-compose: exact status board must not carry a window suffix (got '\(board.title)')")
            }
            if board.groups.reduce(0, { $0 + $1.count }) != 720 {
                problems.append("leads-compose: exact status counts must sum to the table total")
            }
            if Set(board.groups.map { $0.label }) != ["Scraped", "Personalized", "Unknown"] {
                problems.append("leads-compose: exact status labels unexpected")
            }
        } else { problems.append("leads-compose: exact by-status is not a status board") }
        let noStatus = DashboardInputs(leads: sampleLeads, totalCount: 720)
        if case .statusBoard(let board)? = DashboardBuilder.widgetData(noStatus)["by-status"],
           !board.title.contains("(latest") {
            problems.append("leads-compose: fallback status board must carry the window suffix")
        }
        if case .chart(let c)? = DashboardBuilder.build(clean).widgets["added-weekly"],
           c.title.contains("partial") {
            problems.append("leads-compose: clean load must not title the chart partial")
        }

        // A partial load surfaces in the chart title (the partial signal moved there
        // when recent-leads left the grid, P3).
        if case .chart(let c)? = DashboardBuilder.build(laneFailed).widgets["added-weekly"],
           !c.title.contains("partial") {
            problems.append("leads-compose: partial must surface in the added-weekly title")
        }

        // leadIDs (the lane/replied page parser): an unparseable 2xx body is a
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
        if !blackout.degradedReads.contains(where: { $0.contains("unreadable") }) {
            problems.append("leads-compose: an empty read must name itself (got \(blackout.degradedReads))")
        }

        // The send_queue page parser: the PRODUCER half of the flat-zero-trend
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

        // A failed send_queue read must degrade, not render as a book nobody emailed.
        let sendsFailed = LeadsRepository.compose(
            leads: sampleLeads, totalCount: sampleLeads.count, leadsComplete: true,
            messaged: ([], ok: false))
        if !sendsFailed.partial || !sendsFailed.degradedReads.contains("outreach history") {
            problems.append("leads-compose: a failed send_queue read must mark partial and name itself "
                + "(got \(sendsFailed.degradedReads))")
        }
        if sendsFailed.lanesDegraded {
            problems.append("leads-compose: a failed send_queue read must not disable the lane menu")
        }

        // tally (the paged read's pure page parser): an unparseable 2xx body must
        // read as a FAILED page (nil), never as "empty & complete" — the review-fix
        // pin for the partial-honesty contract.
        if LeadsRepository.tally(Data("not json".utf8), column: "lead_tier") != nil {
            problems.append("leads-tally: garbage body must be nil (failed read), not empty")
        }
        let page = LeadsRepository.tally(
            Data(#"[{"lead_tier":"1"},{"lead_tier":"1"},{"lead_tier":" "},{"lead_tier":null}]"#.utf8),
            column: "lead_tier")
        if page?.counts != ["1": 2] || page?.rows != 4 {
            problems.append("leads-tally: expected {1:2}/4 rows, got \(String(describing: page))")
        }
        if let empty = LeadsRepository.tally(Data("[]".utf8), column: "lead_tier"),
           empty.rows != 0 || !empty.counts.isEmpty {
            problems.append("leads-tally: [] must be an EMPTY page (0 rows), not a failure")
        } else if LeadsRepository.tally(Data("[]".utf8), column: "lead_tier") == nil {
            problems.append("leads-tally: [] must parse (empty page), not read as failed")
        }

        // Voice caveats: a degraded/floored tier read speaks "incomplete", which is
        // distinct from the recency-window "sampled" note (source/industry).
        let spoken = LeadAnswers.breakdown(["1": 2], singular: "tier", plural: "tiers",
                                           incomplete: true)
        if !spoken.contains("may be incomplete") {
            problems.append("leads-voice: incomplete tally must carry the caveat (got \(spoken))")
        }
        if LeadAnswers.breakdown(["1": 2], singular: "tier", plural: "tiers").contains("incomplete") {
            problems.append("leads-voice: a clean tally must not carry the incomplete caveat")
        }

        return problems
    }

    /// Exercises the backlog compose (P6): enrollment exclusion + excluded
    /// count, GENERIC reason bucketing (a novel reason must not vanish),
    /// cohort ("?","?") fallbacks + largest-first ordering, truncation flag.
    /// Mirrors ce doctor's check_dead_ends semantics exactly.
    private static func backlogComposeChecks() -> [String] {
        var problems: [String] = []
        func flag(_ id: String?, reason: String?, source: String? = "sales-nav",
                  query: String? = "biotech-europe") -> CampaignReadyRow {
            CampaignReadyRow(leadId: id, leadSource: source, searchQuery: query,
                             blockingReason: reason)
        }

        let composed = BacklogRepository.compose(
            flagged: [
                flag("a", reason: "unedited"),
                flag("b", reason: "unedited"),
                flag("c", reason: "unedited", source: "gmaps-leads", query: "coffee carts"),
                flag("d", reason: "no_email_yet"),          // novel reason — must survive
                flag("e", reason: nil, source: nil, query: nil),   // all fallbacks
                flag("x", reason: "unedited"),              // enrolled → excluded
                flag(nil, reason: "unedited"),              // nil id → NOT excludable, counted
            ],
            enrolled: ["x", "unrelated"],
            scanTruncated: true)
        if composed.byReason != ["unedited": 4, "no_email_yet": 1, "?": 1] {
            problems.append("backlog: reason buckets wrong (got \(composed.byReason))")
        }
        if composed.alreadyEnrolled != 1 {
            problems.append("backlog: exactly one enrolled lead must be excluded")
        }
        // Full ordering pin: largest first, then (source, query) ascending
        // tiebreak — and never force-unwrap (a regression must report, not
        // crash the harness).
        let cohortTuples = composed.cohorts.map { ($0.source, $0.query, $0.count) }
        let expectedCohorts = [("sales-nav", "biotech-europe", 4),
                               ("?", "?", 1),
                               ("gmaps-leads", "coffee carts", 1)]
        if cohortTuples.count != expectedCohorts.count
            || !zip(cohortTuples, expectedCohorts).allSatisfy({ $0 == $1 }) {
            problems.append("backlog: cohort ordering/tiebreak wrong (got \(cohortTuples))")
        }
        if !composed.scanTruncated {
            problems.append("backlog: truncation flag must pass through")
        }

        // Fully-enrolled backlog → empty buckets + full excluded count.
        let allEnrolled = BacklogRepository.compose(
            flagged: [flag("a", reason: "unedited"), flag("b", reason: "no_opener")],
            enrolled: ["a", "b"], scanTruncated: false)
        if !allEnrolled.byReason.isEmpty || allEnrolled.alreadyEnrolled != 2 {
            problems.append("backlog: fully-enrolled set must compose empty + count 2 excluded")
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
                interactionType: "email", direction: direction, subject: "s",
                summary: nil, transcript: nil,
                metadata: sentiment.map { .object(["sentiment": .string($0),
                                                   "intent": .string("question")]) },
                source: nil, interactionAt: at)
        }

        // Sentiment comes from the LATEST inbound row; outbound rows and older
        // inbound sentiments are ignored. Out-of-order input gets re-sorted.
        let composed = ProfileRepository.compose(
            lead: lead,
            enrichment: (nil, ok: true),
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

        // A failed supplementary read marks partial; empty timeline never crashes.
        let degraded = ProfileRepository.compose(
            lead: lead, enrichment: (nil, ok: false), interactions: ([], ok: true))
        if !degraded.partial { problems.append("profile: failed enrichment must mark partial") }
        if degraded.sentiment != nil { problems.append("profile: empty timeline must yield nil sentiment") }
        let failedTimeline = ProfileRepository.compose(
            lead: lead, enrichment: (nil, ok: true), interactions: ([], ok: false))
        if !failedTimeline.interactionsFailed || !failedTimeline.partial {
            problems.append("profile: failed interactions read must set interactionsFailed + partial")
        }

        // PRODUCTION SHAPE (QA live finding): metadata jsonb is DOUBLE-ENCODED —
        // a JSON string, not an object. meta() must decode it or the sentiment
        // badge is dead against every real lead.
        let doubleEncoded = ProfileRepository.compose(
            lead: lead, enrichment: (nil, ok: true),
            interactions: ([LeadInteractionRow(
                interactionType: "email", direction: "inbound", subject: nil,
                summary: nil, transcript: nil,
                metadata: .string(#"{"sentiment": "positive", "intent": "interested"}"#),
                source: nil, interactionAt: "2026-07-01T10:00:00+00:00")], ok: true))
        if doubleEncoded.sentiment != "positive" || doubleEncoded.intent != "interested" {
            problems.append("profile: double-encoded metadata must decode "
                + "(got \(String(describing: doubleEncoded.sentiment)))")
        }

        // Metadata that is garbage / non-object stays harmless.
        let noMeta = ProfileRepository.compose(
            lead: lead, enrichment: (nil, ok: true),
            interactions: ([LeadInteractionRow(
                interactionType: "email", direction: "inbound", subject: nil,
                summary: nil, transcript: nil, metadata: .string("oops"),
                source: nil, interactionAt: "t")], ok: true))
        if noMeta.sentiment != nil {
            problems.append("profile: non-object metadata must not fabricate sentiment")
        }

        // Chronology is by PARSED date: mixed Z / +00:00 / fractional formats
        // and a nil timestamp must still order correctly (nil sinks first).
        let mixed = ProfileRepository.compose(
            lead: lead, enrichment: (nil, ok: true),
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
            lead: lead, enrichment: (nil, ok: true),
            interactions: ((0...cap).map(stamped), ok: true))   // cap+1 rows
        if !overCap.interactionsTruncated || overCap.interactions.count != cap {
            problems.append("profile: cap+1 rows must trim to newest cap + flag truncated")
        }
        if overCap.interactions.first?.interactionAt == stamped(0).interactionAt {
            problems.append("profile: truncation must drop the OLDEST row, not the newest")
        }
        let atCap = ProfileRepository.compose(
            lead: lead, enrichment: (nil, ok: true),
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
        let enrichment = LeadEnrichmentRow(
            casualizedFirstName: " Ana ", casualizedCompanyName: "", casualizedCityName: nil,
            personalizationProject: "roof retrofits", personalizationDetail: nil,
            personalizedOpener: "opener", personalizedOffer: nil,
            enrichmentSource: "local-web-research", enrichmentStatus: "partial",
            leadTier: "2", webResearchJson: nil)
        let pFacts = ProfileFacts.personalization(enrichment)
        if pFacts.map(\.label) != ["Casual name", "Project ref", "Source", "Status"] {
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
        if !Pasteboard.copy("selftest-probe")
            || NSPasteboard.general.string(forType: .string) != "selftest-probe" {
            problems.append("copy: pasteboard round-trip failed")
        }
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

    /// Exercises the campaigns data path: name-join (trim/case-fold), same-source
    /// sent/replies binding, unnamed-campaign isolation, "Other" status rollup, the
    /// reply-rate zero guard, and the `partial` (degraded/truncated) surface.
    private static func campaignChecks() -> [String] {
        var problems: [String] = []

        // Empty in → empty out, not partial; the table renders with zero rows.
        let empty = CampaignsRepository.compose(
            campaigns: [], tracking: [], leadRows: [], sendRows: [], partial: false)
        if !empty.summaries.isEmpty || empty.partial {
            problems.append("campaigns: empty compose should be empty + not partial")
        }
        if case .table(let t)? = CampaignBuilder.build(empty).widgets["campaigns-table"], !t.rows.isEmpty {
            problems.append("campaigns: empty build should yield a 0-row table")
        }

        // Fixture: tracking wins for matched names; roster fills the rest; two unnamed
        // campaigns must NOT share a tracking row (and must not grab the decoy below).
        let campaigns = [
            CampaignRow(id: "c1", campaignName: "Alpha", status: "active", createdAt: nil),
            CampaignRow(id: "c2", campaignName: "  Beta  ", status: "paused", createdAt: nil),  // whitespace → "beta"
            CampaignRow(id: "c3", campaignName: nil, status: "active", createdAt: nil),         // unnamed
            CampaignRow(id: "c4", campaignName: nil, status: "active", createdAt: nil),         // unnamed #2
        ]
        let tracking = [
            CampaignTrackingRow(campaignName: "alpha", totalLeads: 120, totalSent: 100, totalReplies: 5, totalBounced: 1, bounceRate: nil),
            CampaignTrackingRow(campaignName: "beta", totalLeads: 60, totalSent: 50, totalReplies: 0, totalBounced: 0, bounceRate: nil),
            CampaignTrackingRow(campaignName: "untitled campaign", totalLeads: 999, totalSent: 999, totalReplies: 999, totalBounced: 0, bounceRate: nil), // decoy
        ]
        let leadRows = [
            CampaignLeadRow(campaignId: "c1", status: "sent"), CampaignLeadRow(campaignId: "c1", status: "sent"),
            CampaignLeadRow(campaignId: "c1", status: "replied"), CampaignLeadRow(campaignId: "c1", status: "pending"),
            CampaignLeadRow(campaignId: "c3", status: "sent"), CampaignLeadRow(campaignId: "c3", status: "sent"),
            CampaignLeadRow(campaignId: "c3", status: "sent"), CampaignLeadRow(campaignId: "c3", status: "sent"),
            CampaignLeadRow(campaignId: "c3", status: "weirdstatus"), CampaignLeadRow(campaignId: "c3", status: "weirdstatus"),
            CampaignLeadRow(campaignId: "c4", status: "pending"),
        ]
        let sendRows = [
            SendQueueRow(campaignId: "c1", sendingAccount: "a@x.com", status: "sent"),
            SendQueueRow(campaignId: "c1", sendingAccount: "a@x.com", status: "sent"),
            SendQueueRow(campaignId: "c3", sendingAccount: "b@x.com", status: "sent"),
            SendQueueRow(campaignId: "c4", sendingAccount: "a@x.com", status: "pending"),  // not 'sent' → ignored
        ]
        let inputs = CampaignsRepository.compose(
            campaigns: campaigns, tracking: tracking, leadRows: leadRows, sendRows: sendRows, partial: false)
        let byId = Dictionary(uniqueKeysWithValues: inputs.summaries.map { ($0.id, $0) })

        // Matched name → tracking sent/replies (NOT roster's 2 sent / 1 reply).
        if byId["c1"]?.totalSent != 100 || byId["c1"]?.totalReplies != 5 {
            problems.append("campaigns: matched campaign should bind sent/replies from tracking")
        }
        // Whitespace name normalizes to match "beta".
        if byId["c2"]?.totalSent != 50 {
            problems.append("campaigns: trimmed name should join tracking ('  Beta  ' → 'beta')")
        }
        // Unnamed → roster fallback, and MUST NOT pick up the "untitled campaign" decoy.
        if byId["c3"]?.totalSent != 4 {
            problems.append("campaigns: unnamed campaign should use roster sent (4), not the decoy tracking row")
        }
        if byId["c4"]?.totalSent != 0 {
            problems.append("campaigns: second unnamed campaign should not share c3/decoy numbers")
        }

        let built = CampaignBuilder.build(inputs)
        // Aggregate KPIs: 3 active, sent 100+50+4+0 = 154.
        if case .kpi(let k)? = built.widgets["kpi-active"], Int(k.value) != 3 {
            problems.append("campaigns: active-campaign KPI should be 3 (got \(Int(k.value)))")
        }
        if case .kpi(let k)? = built.widgets["kpi-sent"], Int(k.value) != 154 {
            problems.append("campaigns: emails-sent KPI should sum to 154 (got \(Int(k.value)))")
        }
        // Non-canonical statuses roll into an "Other" group on the funnel.
        if case .statusBoard(let b)? = built.widgets["funnel-c3"] {
            if !b.groups.contains(where: { $0.label == "Other" && $0.count == 2 }) {
                problems.append("campaigns: non-canonical statuses should roll into 'Other' (count 2)")
            }
        } else {
            problems.append("campaigns: c3 should have a funnel status board")
        }
        // by-account counts only delivered sends (a@x.com=2, b@x.com=1; the pending row drops).
        if case .statusBoard(let b)? = built.widgets["by-account"] {
            let total = b.groups.reduce(0) { $0 + $1.count }
            if total != 3 { problems.append("campaigns: by-account should count 3 sent (got \(total))") }
        } else {
            problems.append("campaigns: by-account status board missing")
        }
        // Reply-rate zero guard: exactly one campaign (c4, sent=0) renders "—".
        if case .table(let t)? = built.widgets["campaigns-table"] {
            let dashes = t.rows.filter { if case .string("—")? = $0["reply_rate"] { return true }; return false }.count
            if dashes != 1 {
                problems.append("campaigns: exactly one zero-sent campaign should show '—' reply rate (got \(dashes))")
            }
            if t.title.contains("partial") {
                problems.append("campaigns: non-partial load should not mark the table partial")
            }
        } else {
            problems.append("campaigns: campaigns-table should be a table")
        }

        // partial=true surfaces in the table title (degraded/truncated honesty).
        let degraded = CampaignsRepository.compose(
            campaigns: campaigns, tracking: tracking, leadRows: leadRows, sendRows: sendRows, partial: true)
        if case .table(let t)? = CampaignBuilder.build(degraded).widgets["campaigns-table"], !t.title.contains("partial") {
            problems.append("campaigns: partial load should mark the table title 'partial'")
        }

        // ── Roster left-join (P4 inspector) ─────────────────────────────────
        func rosterRow(_ id: String?, status: String = "sent") -> CampaignRosterRow {
            CampaignRosterRow(leadId: id, status: status, addedAt: "2026-07-01T00:00:00+00:00")
        }
        let names = ["L1": LeadSearchHit(id: "L1", companyName: "Acme", email: "a@x.com"),
                     "L2": LeadSearchHit(id: "L2", companyName: nil, email: "b@x.com")]
        let roster = CampaignsRepository.composeRoster(
            rows: [rosterRow("L1"), rosterRow("L2"), rosterRow("L3"), rosterRow(nil)],
            names: names)
        if roster.map(\.leadId) != ["L1", "L2", "L3"] {
            problems.append("campaigns: roster must preserve order + drop nil lead_ids "
                + "(got \(roster.map(\.leadId)))")
        }
        if roster.first?.companyName != "Acme" {
            problems.append("campaigns: roster join lost the lead name")
        }
        if roster[1].companyName != nil || roster[1].email != "b@x.com" {
            problems.append("campaigns: nil company must keep email fallback")
        }
        if roster[2].companyName != nil || roster[2].email != nil {
            problems.append("campaigns: unmatched lead must keep nils (left join)")
        }
        if CampaignsRepository.composeRoster(rows: [], names: [:]).isEmpty == false {
            problems.append("campaigns: empty roster must compose empty")
        }

        return problems
    }

    private static func kindName(_ data: WidgetData) -> String {
        switch data {
        case .kpi: return "kpi"
        case .chart: return "chart"
        case .table: return "table"
        case .statusBoard: return "status-board"
        }
    }

    /// Assert a LayoutSpec is renderable at every breakpoint: each widget has a rect,
    /// each rect in-bounds (0 ≤ x, x+w ≤ cols, w/h ≥ 1), and no two widgets overlap.
    /// Checks the UNION of every breakpoint source (spec.breakpoints, spec.cols, and
    /// each widget's layout keys) so a rect emitted for a breakpoint the spec disagrees
    /// on can't slip past unvalidated, and asserts per-breakpoint rect presence — both
    /// guard against a future packer regression, not just today's output.
    private static func validateGrid(_ spec: LayoutSpec, label: String) -> [String] {
        var problems: [String] = []
        var bps = Set(spec.breakpoints.keys)
        bps.formUnion(spec.cols.keys)
        for w in spec.widgets { bps.formUnion(w.layouts.keys) }

        for bp in bps.sorted() {
            guard let cols = spec.cols[bp] else {
                problems.append("\(label): no cols defined for breakpoint '\(bp)'")
                continue
            }
            var rects: [(id: String, r: GridRect)] = []
            for widget in spec.widgets {
                guard let rect = widget.layouts[bp] else {
                    problems.append("\(label): widget '\(widget.id)' missing rect at \(bp)")
                    continue
                }
                rects.append((widget.id, rect))
            }
            for (id, r) in rects {
                if r.x < 0 || r.y < 0 || r.w < 1 || r.h < 1 {
                    problems.append("\(label): widget '\(id)' has invalid rect at \(bp) (\(r.x),\(r.y),\(r.w),\(r.h))")
                }
                if r.x + r.w > cols {
                    problems.append("\(label): widget '\(id)' overflows \(bp) cols (\(r.x)+\(r.w) > \(cols))")
                }
            }
            for i in rects.indices {
                for j in (i + 1)..<rects.count {
                    if overlaps(rects[i].r, rects[j].r) {
                        problems.append("\(label): '\(rects[i].id)' overlaps '\(rects[j].id)' at \(bp)")
                    }
                }
            }
        }
        return problems
    }

    /// Half-open rectangle intersection on the integer grid.
    private static func overlaps(_ a: GridRect, _ b: GridRect) -> Bool {
        let xOverlap = a.x < b.x + b.w && b.x < a.x + a.w
        let yOverlap = a.y < b.y + b.h && b.y < a.y + a.h
        return xOverlap && yOverlap
    }

    /// Exercises the pipeline data path (all pure): test-vertical filtering, the
    /// runsCap window, stage grouping/ordering, funnel/drops widgets, duration
    /// formatting, the 7-day KPI window (injected `now`), the `partial` surface,
    /// and JSONValue's deterministic pretty-printing (the inspector's renderer).
    private static func pipelineChecks() -> [String] {
        var problems: [String] = []

        func run(_ id: String, vertical: String? = "toy", status: String? = "succeeded",
                 started: String? = "2026-07-08T10:00:00+00:00",
                 finished: String? = "2026-07-08T10:12:30+00:00") -> PipelineRunRow {
            PipelineRunRow(runId: id, kind: "full", vertical: vertical,
                           searchQuery: nil, status: status, error: nil, gitSha: nil,
                           startedAt: started, finishedAt: finished)
        }
        func stage(_ rid: String, _ name: String, seq: Int, inN: Int?, outN: Int?,
                   status: String = "succeeded", drops: [String: Double]? = nil) -> PipelineStageRow {
            PipelineStageRow(id: seq, runId: rid, stage: name, seq: seq, status: status,
                             countIn: inN, countOut: outN, drops: drops, spend: nil,
                             error: nil, startedAt: nil, finishedAt: nil)
        }

        // Empty in → empty out, not partial.
        let empty = PipelineRepository.compose(runs: [], stageRows: [], partial: false)
        if !empty.runs.isEmpty || empty.partial {
            problems.append("pipeline: empty compose should be empty + not partial")
        }

        // `__` test verticals are hidden (same convention as ce status).
        let composed = PipelineRepository.compose(
            runs: [run("r1"), run("__e2e-probe", vertical: "__e2e"), run("r2", status: "running", finished: nil)],
            stageRows: [
                stage("r1", "personalize", seq: 2, inN: 40, outN: 36,
                      drops: ["agent_error": 3, "no_context": 1]),
                stage("r1", "scrape", seq: 1, inN: nil, outN: 50),
                stage("r1", "export", seq: 3, inN: 36, outN: 30, drops: ["unedited": 6]),
            ],
            partial: false)
        if composed.runs.map(\.runId) != ["r1", "r2"] {
            problems.append("pipeline: __ test verticals must be filtered (got \(composed.runs.map(\.runId)))")
        }
        // Stages grouped per run + seq-ordered regardless of fetch order.
        if composed.stagesByRun["r1"]?.map(\.stage) != ["scrape", "personalize", "export"] {
            problems.append("pipeline: stages must be seq-ordered per run")
        }

        // Builder: injected `now` pins the 7d KPI; funnel + drops widgets present.
        let now = DateParse.iso("2026-07-10T00:00:00+00:00")!
        let dash = PipelineBuilder.build(composed, now: now)
        if case .kpi(let k)? = dash.widgets["kpi-runs-7d"], k.value != 2 {
            problems.append("pipeline: runs-7d KPI should count both visible runs (got \(String(describing: dash.widgets["kpi-runs-7d"])))")
        }
        if case .statusBoard(let board)? = dash.widgets["latest-funnel"] {
            if board.groups.map(\.label) != ["scrape –→50", "personalize 40→36", "export 36→30"] {
                problems.append("pipeline: funnel labels/order wrong (got \(board.groups.map(\.label)))")
            }
        } else {
            problems.append("pipeline: latest-funnel widget missing")
        }
        if case .statusBoard(let drops)? = dash.widgets["latest-drops"] {
            // Sorted by count desc then name: unedited 6, agent_error 3, no_context 1.
            if drops.groups.map(\.label) != ["unedited", "agent_error", "no_context"] {
                problems.append("pipeline: drops ordering wrong (got \(drops.groups.map(\.label)))")
            }
        } else {
            problems.append("pipeline: latest-drops widget missing")
        }
        if case .table(let t)? = dash.widgets["runs-table"] {
            if t.title != "Pipeline Runs" {
                problems.append("pipeline: non-partial table title wrong")
            }
            if t.rows.first?["duration"]?.displayString != "12m 30s" {
                problems.append("pipeline: duration format wrong (got \(String(describing: t.rows.first?["duration"])))")
            }
            if t.rows.first?["out"]?.displayString.hasPrefix("30") != true {
                problems.append("pipeline: leads-out should read the LAST stage with a count_out")
            }
        } else {
            problems.append("pipeline: runs-table missing")
        }

        // Partial flag surfaces honestly in the table title.
        let partialDash = PipelineBuilder.build(
            PipelineRepository.compose(runs: [run("r1")], stageRows: [], partial: true), now: now)
        if case .table(let t)? = partialDash.widgets["runs-table"],
           !t.title.contains("partial data") {
            problems.append("pipeline: partial flag must surface in the runs-table title")
        }

        // runsCap window: compose caps the visible list (repository fetches cap+1).
        let many = (0...PipelineRepository.runsCap).map { run("r\($0)") }   // cap+1 runs
        let capped = PipelineRepository.compose(runs: many, stageRows: [], partial: true)
        if capped.runs.count != PipelineRepository.runsCap {
            problems.append("pipeline: compose must cap visible runs at runsCap")
        }

        // Unfinished/missing timestamps render as em-dash, never a negative duration.
        if PipelineBuilder.durationText(started: "2026-07-08T10:00:00+00:00", finished: nil) != "—"
            || PipelineBuilder.durationText(started: nil, finished: nil) != "—" {
            problems.append("pipeline: open-ended durations must render as —")
        }

        // Humanized run labels (P2): name · day · status, with honest fallbacks.
        let label = PipelineBuilder.runLabel(
            runId: "58894ce1-0000", vertical: "biotech-europe", kind: "full",
            startedAt: "2026-07-09T14:00:00+00:00", status: "running")
        if label.primary != "biotech-europe · Jul 9 · running" || label.hex != "58894ce1" {
            problems.append("pipeline: runLabel wrong (got \(label))")
        }
        // NULL vertical = a standalone stage-script run — named, never bare hex.
        let standalone = PipelineBuilder.runLabel(
            runId: "abcd1234-0000", vertical: nil, kind: "stage",
            startedAt: nil, status: nil)
        if standalone.primary != "standalone stage · — · unknown" {
            problems.append("pipeline: NULL-vertical label wrong (got \(standalone.primary))")
        }
        if PipelineBuilder.runLabel(runId: "x", vertical: " ", kind: nil,
                                    startedAt: "not-a-date", status: "ok").primary
            != "standalone run · — · ok" {
            problems.append("pipeline: blank vertical / bad date must fall back cleanly")
        }
        // The runs table leads with the human name and demotes hex to the ID column.
        if case .table(let t)? = dash.widgets["runs-table"] {
            if t.columns.first?.key != "run" || t.columns.last?.key != "id" {
                problems.append("pipeline: runs-table must lead with Run and end with ID")
            }
            if t.rows.first?["run"]?.displayString != "toy"
                || t.rows.first?["id"]?.displayString != "r1" {
                problems.append("pipeline: runs-table row should name the run + demote hex")
            }
        }
        // Funnel title uses the humanized label.
        if case .statusBoard(let b)? = dash.widgets["latest-funnel"],
           !b.title.contains("toy · Jul 8 · succeeded") {
            problems.append("pipeline: funnel title should use the humanized label (got \(String(describing: (dash.widgets["latest-funnel"]))))")
        }

        // Review-fix pins (P5 review round):
        // 1) Phantom-'running' liveness bound — a stale 'running' run must NOT
        //    count as live (it would pin the 8s poll cadence forever).
        let livenessNow = DateParse.iso("2026-07-08T20:00:00+00:00")!
        let fresh = run("fresh", status: "running",
                        started: "2026-07-08T19:30:00+00:00", finished: nil)
        let phantom = run("phantom", status: "running",
                          started: "2026-07-08T02:00:00+00:00", finished: nil)
        let noTimestamp = run("nots", status: "running", started: nil, finished: nil)
        if !PipelineDashboardViewModel.isLiveRunning(fresh, now: livenessNow) {
            problems.append("pipeline: a 30-min-old running run must count as live")
        }
        if PipelineDashboardViewModel.isLiveRunning(phantom, now: livenessNow) {
            problems.append("pipeline: an 18h-old 'running' run is a phantom, not live")
        }
        if PipelineDashboardViewModel.isLiveRunning(noTimestamp, now: livenessNow) {
            problems.append("pipeline: a 'running' run with no started_at must not count as live")
        }
        // 2) Stage window must come from VISIBLE runs — a burst of __ test runs
        //    must not push the latest real run out of its own funnel window.
        let windowRuns = [run("__t1", vertical: "__e2e"), run("__t2", vertical: "__e2e"),
                          run("real1"), run("real2")]
        if PipelineRepository.visibleRuns(windowRuns).map(\.runId) != ["real1", "real2"] {
            problems.append("pipeline: visibleRuns must filter __ test runs before windowing")
        }
        // 3) Event key stays unique even when the optional PK is nil.
        let nilIdEvent = { (stage: String) in
            PipelineLeadEventRow(id: nil, runId: "r1", stage: stage, leadId: "l1",
                                 status: "ok", dropReason: nil, input: nil,
                                 output: nil, createdAt: "t1")
        }
        if nilIdEvent("research").stableKey == nilIdEvent("personalize").stableKey {
            problems.append("pipeline: nil-id events must not share a stableKey (cards would collapse)")
        }
        // 4) String escaping: newlines/backslashes in copy render escaped, valid-JSON style.
        if JSONValue.string("line1\nline2\\end\t.").prettyPrinted
            != "\"line1\\nline2\\\\end\\t.\"" {
            problems.append("pipeline: JSONValue string escaping wrong: \(JSONValue.string("line1\nline2\\end\t.").prettyPrinted)")
        }

        // JSONValue: deterministic pretty-print (sorted keys, ints without .0).
        let snapshot = JSONValue.object([
            "opener": .string("Saw the Tempe expansion"),
            "confidence": .number(3),
            "valid": .bool(true),
            "tags": .array([.string("a"), .null]),
        ])
        let expected = """
        {
          "confidence": 3,
          "opener": "Saw the Tempe expansion",
          "tags": [
            "a",
            null
          ],
          "valid": true
        }
        """
        if snapshot.prettyPrinted != expected {
            problems.append("pipeline: JSONValue pretty-print not deterministic/expected:\n\(snapshot.prettyPrinted)")
        }

        return problems
    }
}
