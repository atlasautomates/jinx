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
        async let deep = leadIDsResult(table: "lead_enrichment",
                                       filter: URLQueryItem(name: "deep_cohort_run_id", value: "not.is.null"))
        async let personalized = leadIDsResult(table: "lead_enrichment",
                                               filter: URLQueryItem(name: "personalized_opener", value: "not.is.null"))
        async let replied = leadIDsResult(table: "replies", filter: nil)
        async let messaged = messagedSendsResult()
        let page = try await allLeads()
        // The count is sampled AFTER the walk, not concurrently with it. Concurrently
        // it is a T0 sample while the walk covers [T0, T0+Δ] — and because `leads.id`
        // is a random uuid, a row inserted mid-walk lands below the cursor about half
        // the time and is missed forever, while `distinct >= totalCount(T0)` still
        // holds. The completeness flag would then be satisfied by exactly the loss it
        // exists to catch. Sampling after costs one serialized round trip (~100 ms)
        // and makes any concurrent insert force the flag closed.
        let total = try await totalCount()
        return Self.compose(
            leads: page.rows, totalCount: total, leadsComplete: page.complete,
            deep: await deep, personalized: await personalized, replied: await replied,
            messaged: await messaged)
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
        messaged: (events: [DashboardInputs.SentEvent], ok: Bool) = ([], true)
    ) -> DashboardInputs {
        // Completeness is judged on DISTINCT ids, never on row count. Row count is
        // exactly what a duplicate inflates, so `rows >= total` would be satisfied
        // BY the bug it exists to catch — a walk that dropped rows and re-read
        // others would declare itself complete.
        let distinct = Set(leads.map(\.id)).count
        var degraded: [String] = []
        if !deep.ok || !personalized.ok { degraded.append("personalization lanes") }
        if !replied.ok { degraded.append("replies") }
        if !messaged.ok { degraded.append("outreach history") }
        // An EMPTY book is not a state this database reaches — and under anon+RLS a
        // revoked or missing SELECT policy returns HTTP 200 with `[]`, not an error.
        // Every guard here would read that as a genuine empty table: `0 >= 0` even
        // satisfies the completeness test, so a grant blackout rendered as a clean,
        // complete, freshly-stamped dashboard showing 0 scraped / 0 emailed /
        // 0 replies. This project has already had one anon-permission lockdown.
        // Fail CLOSED and name the cause.
        if leads.isEmpty || totalCount == 0 {
            degraded.append("lead table unreadable (check anon RLS)")
        }
        return DashboardInputs(
            leads: leads, totalCount: totalCount,
            leadsComplete: leadsComplete && distinct >= totalCount && !leads.isEmpty,
            deepLaneLeadIDs: deep.ids,
            personalizedLeadIDs: personalized.ids,
            repliedLeadIDs: replied.ids,
            lanesDegraded: !deep.ok || !personalized.ok,
            partial: !degraded.isEmpty,
            degradedReads: degraded,
            messagedSends: messaged.events)
    }

    /// Exact total number of leads in the table.
    func totalCount() async throws -> Int {
        try await client.count("leads")
    }

    /// The whole lead table, paged by KEYSET on the primary key.
    ///
    /// Not `offset`. The pipeline writes leads continuously and this walk runs every
    /// ten minutes for days: with `offset` over any ordering, a row inserted between
    /// two requests shifts every later row down one, so the page boundary re-reads
    /// rows already fetched AND skips others. That failure is silent three times
    /// over — duplicates inflate every count, the dropped rows are simply absent,
    /// and the inflated row count SATISFIES the `rows >= totalCount` completeness
    /// test, so the snapshot claims to be the whole book precisely when it isn't.
    /// (Simulated: 2,500 rows + 3 inserts per page → 9 duplicates, 72 rows missed,
    /// `complete == true`.)
    ///
    /// Keying on `id` (an immutable uuid PK) makes the walk immune to inserts by
    /// construction, and `id` is a TOTAL order, so no tie can reorder between pages.
    /// Display order is `created_at desc`, applied locally once the walk is done —
    /// ordering the query by `created_at` would put NULLs first under Postgres's
    /// DESC NULLS FIRST default and make the keyset cursor unrepresentable.
    ///
    /// `complete` is false when the page cap was hit — callers must then stop
    /// presenting derived figures as full-table totals.
    func allLeads(pageSize: Int = LeadsRepository.pageSize,
                  maxPages: Int = LeadsRepository.maxPages) async throws -> (rows: [LeadRow], complete: Bool) {
        var rows: [LeadRow] = []
        var seen = Set<String>()
        var cursor: String? = nil
        let size = max(1, pageSize)
        for _ in 0..<max(1, maxPages) {
            try Task.checkCancellation()
            var items = [
                URLQueryItem(name: "select", value: Self.leadColumns),
                URLQueryItem(name: "order", value: "id.asc"),
                URLQueryItem(name: "limit", value: String(size)),
            ]
            if let cursor { items.append(URLQueryItem(name: "id", value: "gt.\(cursor)")) }
            let data = try await client.get("leads", items)
            let page = try JSONDecoder().decode([LeadRow].self, from: data)
            // Terminate on an EMPTY page, not a short one: the server's own row cap
            // can sit below ours, and a short page would then read as "that's the
            // whole table" while leaving rows behind.
            if page.isEmpty { return (Self.newestFirst(rows), true) }
            for row in page where seen.insert(row.id).inserted { rows.append(row) }
            cursor = page.last?.id
        }
        return (Self.newestFirst(rows), false)
    }

    /// Display order: newest first, ties broken by id descending so the order is
    /// total and stable across refreshes. Rows with no `created_at` sort last —
    /// they are unplaceable in time, and putting them at the top of a list titled
    /// by recency would be a claim we can't support.
    static func newestFirst(_ rows: [LeadRow]) -> [LeadRow] {
        rows.sorted { a, b in
            switch (DateParse.iso(a.createdAt), DateParse.iso(b.createdAt)) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.id > b.id
            }
        }
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
            URLQueryItem(name: "order", value: "created_at.desc.nullslast,id.desc"),
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
    /// `&` and `=` are dropped too, though they are safe TODAY. They are safe only
    /// because `URLComponents` percent-encodes them inside a query value — a
    /// Foundation behaviour nothing in this codebase pins, and the same layer whose
    /// treatment of `+` is already worked around two functions below. If the request
    /// builder is ever swapped for manual string assembly, `x&or=(…)` becomes a
    /// second `or` parameter, and PostgREST merges repeated `or`s. Dropping them
    /// makes the guarantee independent of the HTTP layer. `+` goes for a plainer
    /// reason: PostgREST decodes it as a space, so `AT+T` silently searched for
    /// "AT T" and returned "no lead matches" — the one failure this feature cannot
    /// have.
    ///
    /// `_` (LIKE's single-character wildcard) is deliberately KEPT: it can only
    /// widen a match, and stripping it would break the literal search for a name
    /// that actually contains one. A term made ONLY of `_` is refused below.
    static func searchTerm(_ raw: String) -> String? {
        let denied: Set<Character> = [",", "(", ")", "*", "%", "\\", "\"", "&", "=", "+"]
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
        guard capped.count >= searchMinLength else { return nil }
        // All-wildcard is not a search: "__" passes the length floor and matches
        // essentially every row, which is the same "match everything" the `%` ban
        // exists to prevent.
        guard capped.contains(where: { $0 != "_" }) else { return nil }
        return capped
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
            URLQueryItem(name: "order", value: "created_at.desc.nullslast,id.desc"),
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
    /// Keyset-paged on the TABLE'S OWN `id`, not on `lead_id`.
    ///
    /// `replies` carries several rows per lead — that is why this reads a distinct
    /// SET — so `order=lead_id` is not a total order there, and Postgres gives no
    /// stable order to equal keys. With `LIMIT/OFFSET` that silently skips rows at
    /// every page boundary, understating the replied set and therefore the headline
    /// reply rate. The row `id` is unique in both tables this reads.
    func leadIDsResult(table: String, filter: URLQueryItem?,
                       pageSize: Int = LeadsRepository.pageSize,
                       maxPages: Int = LeadsRepository.maxPages) async -> (ids: Set<String>, ok: Bool) {
        var ids = Set<String>()
        var cursor: String? = nil
        let size = max(1, pageSize)
        do {
            for _ in 0..<max(1, maxPages) {
                try Task.checkCancellation()
                var items = [
                    URLQueryItem(name: "select", value: "id,lead_id"),
                    URLQueryItem(name: "order", value: "id.asc"),
                    URLQueryItem(name: "limit", value: String(size)),
                ]
                if let cursor { items.append(URLQueryItem(name: "id", value: "gt.\(cursor)")) }
                if let filter { items.append(filter) }
                let data = try await client.get(table, items)
                guard let page = Self.leadIDs(data) else {
                    NSLog("LeadsRepository: \(table).lead_id page unparseable; marking partial")
                    return (ids, false)
                }
                if page.rows == 0 { return (ids, true) }
                ids.formUnion(page.ids)
                // Advance by the LAST ROW's id, whatever its lead_id was — a page of
                // null lead_ids must still move the cursor or the walk never ends.
                guard let next = page.cursor else { return (ids, false) }
                cursor = next
            }
            return (ids, false)   // page cap hit → the set is a floor, not the truth
        } catch {
            if isCancellation(error) { return (ids, false) }
            NSLog("LeadsRepository: \(table).lead_id read failed (\(error.localizedDescription)); treating as empty+partial")
            return (ids, false)
        }
    }

    /// Pure parse of one `select=id,lead_id` page (selftest target). nil = the body
    /// wasn't the expected JSON array, which is a FAILED read, never an empty one.
    /// `rows` counts every row returned (including null/blank lead ids) and `cursor`
    /// is the last row's own id, so paging advances by what the server actually sent.
    static func leadIDs(_ data: Data) -> (ids: Set<String>, rows: Int, cursor: String?)? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var ids = Set<String>()
        for row in rows {
            guard let raw = row["lead_id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { ids.insert(id) }
        }
        return (ids, rows.count, Self.cursor(from: rows.last))
    }

    /// SENT emails over the last `weeks` weeks (`send_queue`, `status=sent`), each
    /// carrying its `lead_id` so the trend can count DISTINCT leads messaged per
    /// week rather than send steps — and so it can be narrowed to a filtered lead
    /// set. PAGED because a single 1000-row read stops covering the window as soon
    /// as the send log passes 1000 rows in 13 weeks; keyset-ordered by `id` (a
    /// random uuid), so a partial walk under-counts UNIFORMLY across the window
    /// rather than truncating the oldest weeks. Supplementary → fails open to
    /// whatever was read, with `ok` telling the caller which it was. NOTE: the cutoff is emitted
    /// by a plain `ISO8601DateFormatter` (default GMT, `…Z` suffix, no `+`), which
    /// `URLComponents` passes through unmangled — do not switch it to a `+00:00`
    /// form or the `gte` filter breaks.
    /// Returns an `ok` flag like every sibling read. It used to return a bare array,
    /// which made it the ONE supplementary read whose failure was invisible: a
    /// thrown request, an unparseable page or an exhausted page cap all returned
    /// "here are the sends" and the trend rendered a flat zero line reading
    /// "0 this wk · 0 total" — identical to a book nobody has ever emailed, against
    /// a live table holding 1,234 sends. A mid-walk failure is worse than a total
    /// one: the walk is newest-first, so losing a later page deletes the OLDEST
    /// weeks and draws a tidy "outreach started three weeks ago" ramp.
    func messagedSendsResult(weeks: Int = 13,
                             pageSize: Int = LeadsRepository.pageSize,
                             maxPages: Int = LeadsRepository.maxPages)
        async -> (events: [DashboardInputs.SentEvent], ok: Bool) {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let cutoff = cal.date(byAdding: .weekOfYear, value: -max(1, weeks), to: Date()) ?? Date.distantPast
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)
        var events: [DashboardInputs.SentEvent] = []
        var cursor: String? = nil
        let size = max(1, pageSize)
        do {
            for _ in 0..<max(1, maxPages) {
                try Task.checkCancellation()
                var items = [
                    URLQueryItem(name: "select", value: "id,lead_id,sent_at"),
                    URLQueryItem(name: "status", value: "eq.sent"),
                    URLQueryItem(name: "sent_at", value: "gte.\(cutoffStr)"),
                    URLQueryItem(name: "order", value: "id.asc"),
                    URLQueryItem(name: "limit", value: String(size)),
                ]
                if let cursor { items.append(URLQueryItem(name: "id", value: "gt.\(cursor)")) }
                let data = try await client.get("send_queue", items)
                guard let page = Self.sentEvents(data) else {
                    NSLog("LeadsRepository: send_queue page unparseable; messaged trend degraded")
                    return (events, false)
                }
                if page.rows == 0 { return (events, true) }
                events.append(contentsOf: page.events)
                // A non-empty page with no usable cursor cannot be walked past —
                // report degraded rather than silently returning a prefix.
                guard let next = page.cursor else { return (events, false) }
                cursor = next
            }
            return (events, false)   // page cap hit → a floor, not the whole window
        } catch {
            if isCancellation(error) { return (events, false) }
            NSLog("LeadsRepository: send_queue read failed (\(error.localizedDescription)); messaged trend degraded")
            return (events, false)
        }
    }

    /// Pure parse of one `select=id,lead_id,sent_at` page (selftest target). nil =
    /// the body wasn't the expected JSON array, i.e. a FAILED read.
    ///
    /// This seam exists because the CRITICAL bug it guards — a failed send_queue
    /// read rendering as "nobody was ever emailed" — was fixed in the consumer and
    /// left UNPINNED in the producer: a mutation flipping this page's failure return
    /// to `ok: true` survived the whole suite, because the suite only ever handed
    /// `compose` a tuple it built itself.
    static func sentEvents(_ data: Data)
        -> (events: [DashboardInputs.SentEvent], rows: Int, cursor: String?)? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        let events = rows.compactMap { row -> DashboardInputs.SentEvent? in
            guard let lead = row["lead_id"] as? String,
                  let sent = row["sent_at"] as? String else { return nil }
            return DashboardInputs.SentEvent(leadID: lead, sentAt: sent)
        }
        return (events, rows.count, Self.cursor(from: rows.last))
    }

    /// The keyset cursor for a page: the LAST row's own `id`.
    ///
    /// Accepts a number as well as a string. Every table this walks has a uuid PK
    /// today, but the walk functions are generic over `table`, and a `bigserial` id
    /// would decode as a number — the cast would yield nil, the walk would stop after
    /// one page, and the only symptom would be a permanent red chip with nothing
    /// naming the cause.
    static func cursor(from row: [String: Any]?) -> String? {
        guard let raw = row?["id"] else { return nil }
        if let s = (raw as? String)?.nilIfEmpty { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// The four pipeline stages the enrichment layer writes (the DB's forward-only
    /// trigger enforces the same set, in this order).
    static let knownStages = ["scraped", "researched", "personalized", "campaigned"]

    // NOTE: the exact per-stage `count=exact` HEAD reads that used to live here were
    // DELETED with the filter work, not merely bypassed. They answered one question
    // — the unfiltered full-table stage distribution — and the tab now has to answer
    // it for every filter combination, which no fixed set of HEAD requests can do.
    // Leaving them in place while nothing called them is what let a stale branch in
    // the mapping put two different "scraped" figures on one screen. The stage
    // rollup is counted from the snapshot; `leadsComplete` says when that snapshot
    // is the whole book.

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
            var cursor: String? = nil
            for _ in 0..<maxPages {
                try Task.checkCancellation()
                // KEYSET, like every other walk in this file. This was the last
                // OFFSET pager left standing, over a table the pipeline appends to
                // continuously — the same duplicate/skip hazard documented at
                // `allLeads`, in the one place nobody converted, and therefore the
                // one a future reader would copy.
                var items = [
                    URLQueryItem(name: "select", value: "id,\(column)"),
                    URLQueryItem(name: "order", value: "id.asc"),
                    URLQueryItem(name: "limit", value: "1000"),
                ]
                if let cursor { items.append(URLQueryItem(name: "id", value: "gt.\(cursor)")) }
                let data = try await client.get(table, items)
                guard let page = Self.tally(data, column: column) else {
                    // 2xx but unparseable body = degraded read, NOT "empty & complete".
                    NSLog("LeadsRepository: \(table).\(column) page unparseable; marking partial")
                    return (counts, false)
                }
                if page.rows == 0 { return (counts, true) }
                counts.merge(page.counts) { $0 + $1 }
                guard let next = page.cursor else { return (counts, false) }
                cursor = next
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
    static func tally(_ data: Data, column: String)
        -> (counts: [String: Int], rows: Int, cursor: String?)? {
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
        return (counts, rows.count, Self.cursor(from: rows.last))
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
