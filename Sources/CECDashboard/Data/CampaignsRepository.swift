import Foundation

/// Read-only queries for the Campaigns tab. Mirrors `LeadsRepository`: typed rows via
/// the shared `SupabaseClient` (GET-only, anon key). The roster (`campaign_leads`) is
/// the source of truth; `campaigns_tracking` supplies headline sent/reply numbers.
struct CampaignsRepository {
    let client: SupabaseClient

    /// Fetch + compose everything the dashboard needs. `campaigns` is essential (a
    /// throw fails the load); the rest fail-open to empty so a missing table/RLS/network
    /// blip degrades gracefully (empty funnels) instead of blanking the whole tab.
    func fetch() async throws -> CampaignInputs {
        async let campaignsTask = campaigns()                 // essential
        async let trackingTask = tracking()                   // fail-open
        async let leadsTask = campaignLeads()                 // fail-open
        async let sendsTask = sendQueueRows()                 // fail-open

        let campaigns = try await campaignsTask
        let tracking = await trackingTask
        let leadRows = await leadsTask
        let sendRows = await sendsTask

        // Roster status counts per campaign_id.
        var statusByCampaign: [String: [String: Int]] = [:]
        for row in leadRows {
            guard let cid = row.campaignId else { continue }
            let status = (row.status?.nilIfEmpty ?? "unknown").lowercased()
            statusByCampaign[cid, default: [:]][status, default: 0] += 1
        }
        // Roster total per campaign (authoritative count).
        let rosterTotal: [String: Int] = statusByCampaign.mapValues { $0.values.reduce(0, +) }
        // Tracking headline numbers, keyed by campaign name.
        let trackingByName: [String: CampaignTrackingRow] = Dictionary(
            tracking.compactMap { row in row.campaignName.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )

        let summaries: [CampaignSummary] = campaigns.map { c in
            let name = c.campaignName?.nilIfEmpty ?? "Untitled campaign"
            let counts = statusByCampaign[c.id] ?? [:]
            let track = trackingByName[name]
            let sent = track?.totalSent ?? counts["sent", default: 0]
            let replies = track?.totalReplies ?? counts["replied", default: 0]
            let total = rosterTotal[c.id] ?? track?.totalLeads ?? counts.values.reduce(0, +)
            return CampaignSummary(
                id: c.id,
                name: name,
                status: c.status?.nilIfEmpty ?? "unknown",
                leadStatusCounts: counts,
                totalLeads: total,
                totalSent: sent,
                totalReplies: replies
            )
        }
        // Newest first (created_at desc would need the column; campaigns query already
        // orders by created_at desc, so preserve that order).

        // Aggregate sent-by-account from the send_queue (only delivered sends count).
        var sendsByAccount: [String: Int] = [:]
        for row in sendRows where (row.status?.lowercased() == "sent") {
            guard let acct = row.sendingAccount?.nilIfEmpty else { continue }
            sendsByAccount[acct, default: 0] += 1
        }

        return CampaignInputs(summaries: summaries, sendsByAccount: sendsByAccount)
    }

    // MARK: - Table reads

    /// All campaigns, newest first.
    func campaigns() async throws -> [CampaignRow] {
        let data = try await client.get("campaigns", [
            URLQueryItem(name: "select", value: "id,campaign_name,status,sending_account,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        return try JSONDecoder().decode([CampaignRow].self, from: data)
    }

    /// campaigns_tracking headline metrics. Fail-open → [].
    func tracking() async -> [CampaignTrackingRow] {
        await failOpen {
            let data = try await client.get("campaigns_tracking", [
                URLQueryItem(name: "select",
                             value: "campaign_name,total_leads,total_sent,total_replies,total_bounced,bounce_rate"),
                URLQueryItem(name: "limit", value: "500"),
            ])
            return try JSONDecoder().decode([CampaignTrackingRow].self, from: data)
        }
    }

    /// campaign_leads roster (campaign_id + status). Windowed; today ~480 rows. Fail-open → [].
    func campaignLeads() async -> [CampaignLeadRow] {
        await failOpen {
            let data = try await client.get("campaign_leads", [
                URLQueryItem(name: "select", value: "campaign_id,status"),
                URLQueryItem(name: "limit", value: "10000"),
            ])
            return try JSONDecoder().decode([CampaignLeadRow].self, from: data)
        }
    }

    /// send_queue rows (campaign_id + account + status) for the per-account split. Fail-open → [].
    func sendQueueRows() async -> [SendQueueRow] {
        await failOpen {
            let data = try await client.get("send_queue", [
                URLQueryItem(name: "select", value: "campaign_id,sending_account,status"),
                URLQueryItem(name: "limit", value: "20000"),
            ])
            return try JSONDecoder().decode([SendQueueRow].self, from: data)
        }
    }

    /// Run a supplementary read; any error logs + yields an empty array (never fails the load).
    private func failOpen<T>(_ body: () async throws -> [T]) async -> [T] {
        do { return try await body() }
        catch {
            NSLog("CampaignsRepository: supplementary read failed (\(error.localizedDescription)); treating as empty")
            return []
        }
    }
}
