import Foundation

/// Headless verification of the decode contract (run with `--selftest`).
/// Exercises the decode contract plus every pure builder/compose seam.
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
                    leadSource: "gmaps-leads", city: "Tampa", state: "FL", createdAt: "2026-06-10T12:00:00+00:00"),
            LeadRow(id: "2", companyName: "Globex", firstName: "B", industry: "Biotech",
                    leadSource: "sales-nav", city: "Austin", state: "TX", createdAt: "2026-06-12T12:00:00.500+00:00"),
            LeadRow(id: "3", companyName: "Initech", firstName: "C", industry: "Tech",
                    leadSource: "gmaps-leads", city: nil, state: nil, createdAt: nil),
        ]
        let built = DashboardBuilder.build(DashboardInputs(leads: sampleLeads, totalCount: 720))
        // Deterministic plan: tier/sentiment boards are skipped when their
        // supplementary counts are empty (empty board = noise); recent-leads is
        // the native list below the grid now (P3), not a widget.
        if Set(built.layout.widgets.map { $0.id })
            != ["total-leads", "by-source", "by-industry", "added-weekly"] {
            problems.append("builder: unexpected widget ids (\(built.layout.widgets.map { $0.id }.sorted()))")
        }
        problems.append(contentsOf: validateGrid(built.layout, label: "leads-build"))
        if case .kpi(let kpi)? = built.widgets["total-leads"], kpi.value != 720 {
            problems.append("builder: total-leads KPI should reflect totalCount (got \(kpi.value))")
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

        let summary = "widgets=\(dash.layout.widgets.count) data=\(dash.widgets.count) kinds=\(kinds.sorted())"
        if problems.isEmpty {
            print("SELFTEST PASS — \(summary)")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("SELFTEST FAIL — \(summary)\n  - \(problems.joined(separator: "\n  - "))\n".utf8))
            exit(1)
        }
    }

    /// Exercises the Leads compose seam (P1): supplementary results carry an `ok`
    /// flag, and a FAILED read (not an EMPTY table) marks the load partial —
    /// surfaced in the recent-leads table title.
    private static func leadsComposeChecks(sampleLeads: [LeadRow]) -> [String] {
        var problems: [String] = []

        // Both supplementary reads ok (even if empty) → NOT partial.
        let clean = LeadsRepository.compose(
            leads: sampleLeads, totalCount: 10,
            tiers: ([:], ok: true), sentiment: (["positive": 2], ok: true))
        if clean.partial { problems.append("leads-compose: ok reads must not mark partial") }
        if clean.sentimentCounts["positive"] != 2 || !clean.tierCounts.isEmpty {
            problems.append("leads-compose: counts not packaged through")
        }
        if case .chart(let c)? = DashboardBuilder.build(clean).widgets["added-weekly"],
           c.title.contains("partial") {
            problems.append("leads-compose: clean load must not title the chart partial")
        }

        // A failed supplementary read → partial, surfaced in the chart title
        // (the partial signal moved there when recent-leads left the grid, P3).
        let degraded = LeadsRepository.compose(
            leads: sampleLeads, totalCount: 10,
            tiers: ([:], ok: false), sentiment: ([:], ok: true))
        if !degraded.partial { problems.append("leads-compose: failed tier read must mark partial") }
        if case .chart(let c)? = DashboardBuilder.build(degraded).widgets["added-weekly"],
           !c.title.contains("partial") {
            problems.append("leads-compose: partial must surface in the added-weekly title")
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
