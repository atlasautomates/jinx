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
