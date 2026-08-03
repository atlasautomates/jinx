import Foundation

/// Read-only queries against the leads database. Returns typed rows.
struct LeadsRepository {
    let client: SupabaseClient

    /// PostgREST caps every response at 1000 rows regardless of `limit`, so every
    /// full-set read here PAGES. The cap exists only as a runaway guard — hitting
    /// it is a truthfulness event (`leadsComplete: false`), never a silent floor.
    static let pageSize = 1000
    static let maxPages = 25          // 25k leads before the snapshot degrades

    /// Everything the Leads tab needs, in one call.
    ///
    /// The snapshot is the WHOLE lead table (paged), not a recency window: the tab
    /// now filters by lane/region/source/industry, and every headline number is
    /// recomputed from the filtered subset. A windowed snapshot would make each of
    /// those numbers a sample masquerading as a total — the exact-count HEAD reads
    /// that used to backstop the unfiltered totals cannot be issued per filter
    /// combination. So: fetch the book once, derive everything locally, and say so
    /// out loud (`leadsComplete`) if paging ever hits the cap.
    ///
    /// Essential reads (leads, total count) throw and fail the load; every
    /// supplementary read fails OPEN and only marks the result `partial`.
    func fetch() async throws -> DashboardInputs {
        async let leadPage = allLeads()
        async let deep = leadIDsResult(table: "lead_enrichment",
                                       filter: URLQueryItem(name: "deep_cohort_run_id", value: "not.is.null"))
        async let personalized = leadIDsResult(table: "lead_enrichment",
                                               filter: URLQueryItem(name: "personalized_opener", value: "not.is.null"))
        async let replied = leadIDsResult(table: "replies", filter: nil)
        async let messaged = messagedSendsResult()
        let total = try await totalCount()
        let page = try await leadPage
        return Self.compose(
            leads: page.rows, totalCount: total, leadsComplete: page.complete,
            deep: await deep, personalized: await personalized, replied: await replied,
            messagedSends: await messaged)
    }

    /// Pure packaging seam (selftest target): supplementary results carry an `ok`
    /// flag so a FAILED read (partial) is distinguishable from an EMPTY table.
    ///
    /// A failed lane read is louder than a failed tier read was: with `deep` and
    /// `personalized` empty, every lead would classify as "Not personalized" —
    /// a WRONG answer rather than a missing widget. So a failed lane read sets
    /// `lanesDegraded` on top of `partial`, and the filter bar refuses to offer a
    /// lane dimension it cannot compute.
    ///
    /// `leadsComplete` is ANDed with the row count vs. the exact table total: a
    /// clean page walk that still came back short of `totalCount` (rows written
    /// mid-walk, an RLS-invisible row) is not a complete snapshot either.
    static func compose(
        leads: [LeadRow], totalCount: Int, leadsComplete: Bool,
        deep: (ids: Set<String>, ok: Bool) = ([], true),
        personalized: (ids: Set<String>, ok: Bool) = ([], true),
        replied: (ids: Set<String>, ok: Bool) = ([], true),
        messagedSends: [DashboardInputs.SentEvent] = []
    ) -> DashboardInputs {
        DashboardInputs(
            leads: leads, totalCount: totalCount,
            leadsComplete: leadsComplete && leads.count >= totalCount,
            deepLaneLeadIDs: deep.ids,
            personalizedLeadIDs: personalized.ids,
            repliedLeadIDs: replied.ids,
            lanesDegraded: !deep.ok || !personalized.ok,
            partial: !deep.ok || !personalized.ok || !replied.ok,
            messagedSends: messagedSends)
    }

    /// Exact total number of leads in the table.
    func totalCount() async throws -> Int {
        try await client.count("leads")
    }

    /// The whole lead table, newest first, paged.
    ///
    /// Ordered by `(created_at desc, id desc)` — a TOTAL order. Paging on
    /// `created_at` alone is not stable: the hundreds of leads one scrape writes
    /// share a timestamp, and PostgREST may return those ties in a different order
    /// per page, which silently duplicates some rows and drops others across a page
    /// boundary. `id` breaks every tie.
    ///
    /// `complete` is false when the page cap was hit — callers must then stop
    /// presenting derived figures as full-table totals.
    func allLeads(pageSize: Int = LeadsRepository.pageSize,
                  maxPages: Int = LeadsRepository.maxPages) async throws -> (rows: [LeadRow], complete: Bool) {
        var rows: [LeadRow] = []
        let size = max(1, pageSize)
        for _ in 0..<max(1, maxPages) {
            let data = try await client.get("leads", [
                URLQueryItem(name: "select", value: Self.leadColumns),
                URLQueryItem(name: "order", value: "created_at.desc,id.desc"),
                URLQueryItem(name: "limit", value: String(size)),
                URLQueryItem(name: "offset", value: String(rows.count)),
            ])
            let page = try JSONDecoder().decode([LeadRow].self, from: data)
            rows.append(contentsOf: page)
            // Terminate on an EMPTY page, not a short one: the server's own row cap
            // can sit below ours, and a short page would then read as "that's the
            // whole table" while leaving rows behind.
            if page.isEmpty { return (rows, true) }
        }
        return (rows, false)
    }

    /// Columns every lead read selects. `location`/`country` are region inputs
    /// (see `RegionKey`); dropping one silently collapses a region bucket.
    static let leadColumns =
        "id,company_name,first_name,industry,lead_source,city,state,location,country,created_at,enrichment_stage"

    /// Most recently added leads — the voice/`--query` surfaces want a window
    /// rather than the whole book.
    func recentLeads(limit: Int = 1000) async throws -> [LeadRow] {
        let data = try await client.get("leads", [
            URLQueryItem(name: "select", value: Self.leadColumns),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ])
        return try JSONDecoder().decode([LeadRow].self, from: data)
    }

    // MARK: - Search

    /// Longest term we will send. Long enough for any real company name, short
    /// enough that a paste-bomb can't build a pathological ILIKE.
    static let searchTermLimit = 64
    /// Below this, `ilike *x*` matches a large share of the book — the result list
    /// is noise and the scan is expensive for nothing.
    static let searchMinLength = 2
    static let searchResultLimit = 60

    /// Sanitize a raw search-box value into something safe to interpolate into a
    /// PostgREST `or=(…)` filter. nil = don't search (empty / too short).
    ///
    /// This is a filter-GRAMMAR sanitizer and it is the whole security story for
    /// the feature. `or=(a.ilike.*x*,b.ilike.*x*)` is parsed positionally: a comma
    /// in the value starts a new predicate, a parenthesis closes the group, and a
    /// backslash escapes the next character — so an unfiltered term can rewrite the
    /// query into one selecting rows it was never meant to return. `%` is a LIKE
    /// metacharacter that matches everything (turning any search into a full table
    /// dump) and `*` is PostgREST's own wildcard spelling, which we supply
    /// ourselves. Every one of those is DROPPED rather than escaped: an escape has
    /// to survive two layers of decoding to stay correct, a deletion does not.
    ///
    /// `_` (LIKE's single-character wildcard) is deliberately KEPT: it can only
    /// widen a match, and stripping it would break the literal search for a name
    /// that actually contains one.
    static func searchTerm(_ raw: String) -> String? {
        let denied: Set<Character> = [",", "(", ")", "*", "%", "\\", "\""]
        let mapped = String(raw.prefix(searchTermLimit * 8)).map { ch -> Character in
            if ch.isNewline || ch == "\t" { return " " }
            return denied.contains(ch) ? " " : ch
        }
        let stripped = String(mapped).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let capped = String(collapsed.prefix(searchTermLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.count >= searchMinLength ? capped : nil
    }

    /// The `or=` filter value for one sanitized term. Split out so the selftest can
    /// pin the exact grammar without a network call.
    static func searchFilter(_ term: String) -> String {
        let columns = ["company_name", "full_name", "first_name", "last_name", "email"]
        return "(" + columns.map { "\($0).ilike.*\(term)*" }.joined(separator: ",") + ")"
    }

    /// Server-side lead search by company OR person name (also email), newest
    /// first. THROWS on transport/HTTP failure: a search is a foreground action the
    /// user just took, so it must report rather than fail open to an empty list
    /// that reads as "no such lead".
    func search(_ rawTerm: String,
                limit: Int = LeadsRepository.searchResultLimit) async throws -> [LeadRow] {
        guard let term = Self.searchTerm(rawTerm) else { return [] }
        let data = try await client.get("leads", [
            URLQueryItem(name: "select", value: Self.leadColumns + ",last_name,email"),
            URLQueryItem(name: "or", value: Self.searchFilter(term)),
            URLQueryItem(name: "order", value: "created_at.desc,id.desc"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ])
        return try JSONDecoder().decode([LeadRow].self, from: data)
    }

    // MARK: - Supplementary reads

    /// Counts of `lead_enrichment.lead_tier`. Fail-open (`ok: false` marks partial),
    /// so a supplementary widget never fails the dashboard load.
    func tierCountsResult() async -> (counts: [String: Int], ok: Bool) {
        await columnCounts(table: "lead_enrichment", column: "lead_tier")
    }

    /// Counts of `replies.sentiment`. Fail-open.
    func sentimentCountsResult() async -> (counts: [String: Int], ok: Bool) {
        await columnCounts(table: "replies", column: "sentiment")
    }

    /// The DISTINCT set of `lead_id`s in `table` matching `filter` (nil = every
    /// row), paged. Backs the lane classification (deep-lane / personalized) and
    /// the replied set, so the tab can answer "which of THESE leads replied?" under
    /// any filter instead of only reporting the global tally.
    ///
    /// Fail-open: any error yields `ok: false` with whatever was read, and the
    /// caller marks the load partial (and, for lanes, degraded).
    func leadIDsResult(table: String, filter: URLQueryItem?,
                       pageSize: Int = LeadsRepository.pageSize,
                       maxPages: Int = LeadsRepository.maxPages) async -> (ids: Set<String>, ok: Bool) {
        var ids = Set<String>()
        var offset = 0
        let size = max(1, pageSize)
        do {
            for _ in 0..<max(1, maxPages) {
                var items = [
                    URLQueryItem(name: "select", value: "lead_id"),
                    URLQueryItem(name: "order", value: "lead_id"),
                    URLQueryItem(name: "limit", value: String(size)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ]
                if let filter { items.append(filter) }
                let data = try await client.get(table, items)
                guard let page = Self.leadIDs(data) else {
                    NSLog("LeadsRepository: \(table).lead_id page at offset \(offset) unparseable; marking partial")
                    return (ids, false)
                }
                if page.rows == 0 { return (ids, true) }
                ids.formUnion(page.ids)
                offset += page.rows
            }
            return (ids, false)   // page cap hit → the set is a floor, not the truth
        } catch {
            NSLog("LeadsRepository: \(table).lead_id read failed (\(error.localizedDescription)); treating as empty+partial")
            return (ids, false)
        }
    }

    /// Pure parse of one `select=lead_id` page (selftest target). nil = the body
    /// wasn't the expected JSON array, which is a FAILED read, never an empty one.
    /// `rows` counts every row returned (including null/blank ids) so paging
    /// advances by what the server actually sent — advancing by usable ids alone
    /// would re-request the same offset forever if a page were all nulls.
    static func leadIDs(_ data: Data) -> (ids: Set<String>, rows: Int)? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var ids = Set<String>()
        for row in rows {
            guard let raw = row["lead_id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { ids.insert(id) }
        }
        return (ids, rows.count)
    }

    /// SENT emails over the last `weeks` weeks (`send_queue`, `status=sent`), each
    /// carrying its `lead_id` so the trend can count DISTINCT leads messaged per
    /// week rather than send steps — and so it can be narrowed to a filtered lead
    /// set. Newest first and PAGED: a single 1000-row read clips the oldest weeks of
    /// the window as soon as the send log passes 1000 rows in 13 weeks.
    /// Supplementary → fails open to whatever was read. NOTE: the cutoff is emitted
    /// by a plain `ISO8601DateFormatter` (default GMT, `…Z` suffix, no `+`), which
    /// `URLComponents` passes through unmangled — do not switch it to a `+00:00`
    /// form or the `gte` filter breaks.
    func messagedSendsResult(weeks: Int = 13,
                             pageSize: Int = LeadsRepository.pageSize,
                             maxPages: Int = LeadsRepository.maxPages) async -> [DashboardInputs.SentEvent] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let cutoff = cal.date(byAdding: .weekOfYear, value: -max(1, weeks), to: Date()) ?? Date.distantPast
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)
        var events: [DashboardInputs.SentEvent] = []
        var offset = 0
        let size = max(1, pageSize)
        do {
            for _ in 0..<max(1, maxPages) {
                let data = try await client.get("send_queue", [
                    URLQueryItem(name: "select", value: "lead_id,sent_at"),
                    URLQueryItem(name: "status", value: "eq.sent"),
                    URLQueryItem(name: "sent_at", value: "gte.\(cutoffStr)"),
                    URLQueryItem(name: "order", value: "sent_at.desc,id.desc"),
                    URLQueryItem(name: "limit", value: String(size)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ])
                guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                    NSLog("LeadsRepository: send_queue page unparseable; messaged trend truncated")
                    return events
                }
                if rows.isEmpty { return events }
                events.append(contentsOf: rows.compactMap { row in
                    guard let lead = row["lead_id"] as? String,
                          let sent = row["sent_at"] as? String else { return nil }
                    return DashboardInputs.SentEvent(leadID: lead, sentAt: sent)
                })
                // Advance by rows RETURNED, not by events kept — a row with a null
                // lead_id must still move the offset or the walk never terminates.
                offset += rows.count
            }
            return events
        } catch {
            NSLog("LeadsRepository: send_queue read failed (\(error.localizedDescription)); messaged trend omitted")
            return events
        }
    }

    /// The four pipeline stages the enrichment layer writes (the DB's forward-only
    /// trigger enforces the same set, in this order).
    static let knownStages = ["scraped", "researched", "personalized", "campaigned"]

    /// EXACT full-table counts per `enrichment_stage`, via one filtered `count=exact`
    /// HEAD request per stage plus a NULL count. Retained for the voice/`--query`
    /// surfaces and `DashboardBuilder`; the Leads tab derives its stage counts from
    /// the snapshot instead (the same number when the snapshot is complete, and
    /// honestly labelled when it isn't). Fail-open.
    func statusCountsResult(totalCount: Int) async -> (counts: [String: Int], ok: Bool) {
        do {
            var counts: [String: Int] = [:]
            try await withThrowingTaskGroup(of: (String, Int).self) { group in
                for stage in Self.knownStages {
                    group.addTask {
                        (stage, try await client.count("leads", [URLQueryItem(name: "enrichment_stage", value: "eq.\(stage)")]))
                    }
                }
                group.addTask {
                    ("unknown", try await client.count("leads", [URLQueryItem(name: "enrichment_stage", value: "is.null")]))
                }
                for try await (stage, n) in group where n > 0 { counts[stage] = n }
            }
            let residual = totalCount - counts.values.reduce(0, +)
            if residual > 0 { counts["unknown", default: 0] += residual }
            return (counts, true)
        } catch {
            return ([:], false)
        }
    }

    /// Counts-only conveniences for the voice surfaces (`--query`, App Intents) and
    /// SupabaseCheck, which don't track partiality.
    func tierCounts() async -> [String: Int] { await tierCountsResult().counts }
    func sentimentCounts() async -> [String: Int] { await sentimentCountsResult().counts }

    /// Fetch a single string column (PAGED — PostgREST caps every response at 1000
    /// rows regardless of `limit`, so a single big-limit read silently samples) and
    /// tally non-null/non-empty values. Never throws — any transport error OR
    /// unparseable 2xx body yields `ok: false` so the caller can mark the load
    /// partial. Terminates on an EMPTY page (not a short one), so a server row cap
    /// below our limit can't truncate the tally while reporting it complete.
    private func columnCounts(table: String, column: String,
                              maxPages: Int = 20) async -> (counts: [String: Int], ok: Bool) {
        do {
            var counts: [String: Int] = [:]
            var offset = 0
            for _ in 0..<maxPages {
                let data = try await client.get(table, [
                    URLQueryItem(name: "select", value: column),
                    URLQueryItem(name: "order", value: "id"),
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "offset", value: String(offset)),
                ])
                guard let page = Self.tally(data, column: column) else {
                    // 2xx but unparseable body = degraded read, NOT "empty & complete".
                    NSLog("LeadsRepository: \(table).\(column) page at offset \(offset) unparseable; marking partial")
                    return (counts, false)
                }
                if page.rows == 0 { return (counts, true) }
                counts.merge(page.counts) { $0 + $1 }
                offset += page.rows
            }
            // Page cap hit without an empty page: counts are a floor — mark partial.
            return (counts, false)
        } catch {
            NSLog("LeadsRepository: \(table).\(column) read failed (\(error.localizedDescription)); treating as empty+partial")
            return ([:], false)
        }
    }

    /// Pure tally of one PostgREST page (selftest target). Returns nil when the
    /// body isn't the expected JSON array — the caller must treat that as a FAILED
    /// read, never as an empty page.
    static func tally(_ data: Data, column: String) -> (counts: [String: Int], rows: Int)? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var counts: [String: Int] = [:]
        for row in rows {
            guard let raw = row[column] as? String else { continue }   // skip null/non-string
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { continue }
            counts[label, default: 0] += 1
        }
        return (counts, rows.count)
    }

    /// Lightweight connectivity probe: fetch a single id. Used by `--check-supabase`.
    func ping() async throws -> Int {
        let data = try await client.get("leads", [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        // Reachability + auth are already proven by the 2xx in client.get; don't
        // couple the health probe to row shape — just confirm a JSON array came back.
        // (A schema/type drift should fail the real recentLeads() query, not the
        // "can I reach Supabase?" check.)
        let array = try JSONSerialization.jsonObject(with: data) as? [Any]
        return array?.count ?? 0
    }
}
