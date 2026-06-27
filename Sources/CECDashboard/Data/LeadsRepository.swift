import Foundation

/// Read-only queries against the leads database. Returns typed rows; widget-data
/// mapping (replacing MockData) lands next.
struct LeadsRepository {
    let client: SupabaseClient

    /// Exact total number of leads in the table.
    func totalCount() async throws -> Int {
        try await client.count("leads")
    }

    /// Most recently added leads.
    func recentLeads(limit: Int = 1000) async throws -> [LeadRow] {
        let data = try await client.get("leads", [
            URLQueryItem(name: "select",
                         value: "id,company_name,first_name,industry,lead_source,city,state,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ])
        return try JSONDecoder().decode([LeadRow].self, from: data)
    }

    /// Counts of `lead_enrichment.lead_tier`. Fail-open → `[:]` (missing RLS policy /
    /// table / network), so a supplementary widget never fails the dashboard load.
    func tierCounts() async -> [String: Int] {
        await columnCounts(table: "lead_enrichment", column: "lead_tier")
    }

    /// Counts of `replies.sentiment`. Fail-open → `[:]`.
    func sentimentCounts() async -> [String: Int] {
        await columnCounts(table: "replies", column: "sentiment")
    }

    /// Fetch a single string column (windowed) and tally non-null/non-empty values.
    /// Never throws — any error yields an empty tally (the caller treats it as "no data").
    ///
    /// NOTE: `limit` windows the tally. Today these tables are small (lead_enrichment ~647),
    /// so 5000 covers them fully. If a table grows past `limit` the counts become a
    /// 5000-row sample shown as totals (no scope suffix) — revisit (count=exact, or a
    /// "(sampled)" label) before lead_enrichment approaches ~4000 rows.
    private func columnCounts(table: String, column: String, limit: Int = 5000) async -> [String: Int] {
        do {
            let data = try await client.get(table, [
                URLQueryItem(name: "select", value: column),
                URLQueryItem(name: "limit", value: String(limit)),
            ])
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            var counts: [String: Int] = [:]
            for row in rows {
                guard let raw = row[column] as? String else { continue }   // skip null/non-string
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty { continue }
                counts[label, default: 0] += 1
            }
            return counts
        } catch {
            // Fail-open, but log: distinguishes a transient read FAILURE (which briefly
            // empties the signal and can flip the layout cache key → an extra Haiku call)
            // from a genuinely empty table (which returns [:] via the rows path, no log).
            NSLog("LeadsRepository: \(table).\(column) read failed (\(error.localizedDescription)); treating as empty")
            return [:]
        }
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
