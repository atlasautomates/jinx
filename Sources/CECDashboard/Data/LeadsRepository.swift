import Foundation

/// Read-only queries against the leads database. Returns typed rows.
struct LeadsRepository {
    let client: SupabaseClient

    /// Everything the Leads tab needs, in one call (parity with
    /// `CampaignsRepository.fetch` / `PipelineRepository.fetch`): essential reads
    /// throw and fail the load; supplementary tier/sentiment reads fail open and
    /// only mark the result `partial`.
    func fetch() async throws -> DashboardInputs {
        async let total = totalCount()
        async let leads = recentLeads()
        async let tiers = tierCountsResult()
        async let sentiment = sentimentCountsResult()
        return try await Self.compose(
            leads: leads, totalCount: total,
            tiers: await tiers, sentiment: await sentiment)
    }

    /// Pure packaging seam (selftest target): supplementary results carry an `ok`
    /// flag so a FAILED read (partial) is distinguishable from an EMPTY table.
    static func compose(
        leads: [LeadRow], totalCount: Int,
        tiers: (counts: [String: Int], ok: Bool),
        sentiment: (counts: [String: Int], ok: Bool)
    ) -> DashboardInputs {
        DashboardInputs(leads: leads, totalCount: totalCount,
                        tierCounts: tiers.counts,
                        sentimentCounts: sentiment.counts,
                        partial: !tiers.ok || !sentiment.ok)
    }

    /// Exact total number of leads in the table.
    func totalCount() async throws -> Int {
        try await client.count("leads")
    }

    /// Most recently added leads.
    func recentLeads(limit: Int = 1000) async throws -> [LeadRow] {
        let data = try await client.get("leads", [
            URLQueryItem(name: "select",
                         value: "id,company_name,first_name,industry,lead_source,city,state,created_at,enrichment_stage"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ])
        return try JSONDecoder().decode([LeadRow].self, from: data)
    }

    /// Counts of `lead_enrichment.lead_tier`. Fail-open (`ok: false` marks partial),
    /// so a supplementary widget never fails the dashboard load.
    func tierCountsResult() async -> (counts: [String: Int], ok: Bool) {
        await columnCounts(table: "lead_enrichment", column: "lead_tier")
    }

    /// Counts of `replies.sentiment`. Fail-open.
    func sentimentCountsResult() async -> (counts: [String: Int], ok: Bool) {
        await columnCounts(table: "replies", column: "sentiment")
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
