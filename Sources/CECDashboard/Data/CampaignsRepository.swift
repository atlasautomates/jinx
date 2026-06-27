import Foundation

/// Read-only queries for the Campaigns tab. Mirrors `LeadsRepository`: typed rows via
/// the shared `SupabaseClient` (GET-only, anon key). The roster (`campaign_leads`) is
/// the source of truth; `campaigns_tracking` supplies headline sent/reply numbers.
struct CampaignsRepository {
    let client: SupabaseClient

    // Row caps for the windowed reads. We fetch cap+1 and treat MORE than `cap` rows as
    // truncated, so a table holding exactly `cap` rows isn't a false "partial" — the read
    // is complete, the extra probe row just confirms there's nothing beyond.
    private static let leadsCap = 10000
    private static let sendsCap = 20000

    /// Fetch + compose everything the dashboard needs. `campaigns` is essential (a
    /// throw fails the load); the rest fail-open so a missing table/RLS/network blip
    /// degrades gracefully (empty funnels) instead of blanking the whole tab — but the
    /// resulting `partial` flag tells the UI the numbers may be incomplete.
    func fetch() async throws -> CampaignInputs {
        async let campaignsTask = campaigns()                 // essential
        async let trackingTask = tracking()                   // fail-open
        async let leadsTask = campaignLeads()                 // fail-open
        async let sendsTask = sendQueueRows()                 // fail-open

        let campaigns = try await campaignsTask
        let (tracking, trackingOK) = await trackingTask
        let (leadRows, leadsOK) = await leadsTask
        let (sendRows, sendsOK) = await sendsTask

        // Incomplete if any supplementary read failed (auth/RLS/network) OR a windowed
        // read hit its cap (table outgrew the window → undercount).
        let truncated = leadRows.count > Self.leadsCap || sendRows.count > Self.sendsCap
        let degraded = !trackingOK || !leadsOK || !sendsOK || truncated
        if truncated {
            NSLog("CampaignsRepository: windowed read hit its cap (leads=\(leadRows.count), sends=\(sendRows.count)); counts may under-report")
        }

        return Self.compose(
            campaigns: campaigns, tracking: tracking,
            leadRows: leadRows, sendRows: sendRows, partial: degraded
        )
    }

    /// Pure composition of raw rows → dashboard inputs. No I/O, so it's unit-testable
    /// (see SelfTest) and the network path above stays a thin wrapper.
    static func compose(
        campaigns: [CampaignRow],
        tracking: [CampaignTrackingRow],
        leadRows: [CampaignLeadRow],
        sendRows: [SendQueueRow],
        partial: Bool
    ) -> CampaignInputs {
        // Roster status counts per campaign_id.
        var statusByCampaign: [String: [String: Int]] = [:]
        for row in leadRows {
            guard let cid = row.campaignId else { continue }
            let status = (row.status?.nilIfEmpty ?? "unknown").lowercased()
            statusByCampaign[cid, default: [:]][status, default: 0] += 1
        }
        // Roster total per campaign (authoritative count).
        let rosterTotal: [String: Int] = statusByCampaign.mapValues { $0.values.reduce(0, +) }

        // Tracking headline numbers, joined to campaigns by NORMALIZED name (trim + case-
        // fold) — there's no FK, so a stray space or case difference would otherwise drop
        // the join and silently fall back to roster counts.
        let trackingByName: [String: CampaignTrackingRow] = Dictionary(
            tracking.compactMap { row in normalizeName(row.campaignName).map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )

        let summaries: [CampaignSummary] = campaigns.map { c in
            let displayName = c.campaignName?.nilIfEmpty ?? "Untitled campaign"
            let counts = statusByCampaign[c.id] ?? [:]
            // Only join tracking for campaigns that actually have a name — otherwise two
            // unnamed campaigns would both key to "untitled" and share one tracking row.
            let key = normalizeName(c.campaignName)
            let track = key.flatMap { trackingByName[$0] }

            // Bind sent + replies to ONE source so the reply-rate ratio is internally
            // consistent: tracking (provider-aggregated) when matched, else the roster
            // (campaign_leads.status) — never one metric from each.
            let sent: Int
            let replies: Int
            if let track {
                sent = track.totalSent ?? 0
                replies = track.totalReplies ?? 0
            } else {
                sent = counts["sent", default: 0]
                replies = counts["replied", default: 0]
                if key != nil {
                    NSLog("CampaignsRepository: no tracking row for '\(displayName)'; using roster counts")
                }
            }
            let total = rosterTotal[c.id] ?? track?.totalLeads ?? counts.values.reduce(0, +)
            return CampaignSummary(
                id: c.id,
                name: displayName,
                status: c.status?.nilIfEmpty ?? "unknown",
                leadStatusCounts: counts,
                totalLeads: total,
                totalSent: sent,
                totalReplies: replies
            )
        }
        // Order preserved from `campaigns` (already created_at desc, newest first).

        // Aggregate sent-by-account from the send_queue (only delivered sends count).
        var sendsByAccount: [String: Int] = [:]
        for row in sendRows where (row.status?.lowercased() == "sent") {
            guard let acct = row.sendingAccount?.nilIfEmpty else { continue }
            sendsByAccount[acct, default: 0] += 1
        }

        return CampaignInputs(summaries: summaries, sendsByAccount: sendsByAccount, partial: partial)
    }

    /// Trim + case-fold a campaign name for joining; nil/blank → nil (won't key a join).
    static func normalizeName(_ name: String?) -> String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }

    // MARK: - Table reads

    /// All campaigns, newest first.
    func campaigns() async throws -> [CampaignRow] {
        let data = try await client.get("campaigns", [
            URLQueryItem(name: "select", value: "id,campaign_name,status,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        return try JSONDecoder().decode([CampaignRow].self, from: data)
    }

    /// campaigns_tracking headline metrics. Fail-open → (rows: [], ok: false).
    func tracking() async -> (rows: [CampaignTrackingRow], ok: Bool) {
        await failOpen {
            let data = try await client.get("campaigns_tracking", [
                URLQueryItem(name: "select",
                             value: "campaign_name,total_leads,total_sent,total_replies,total_bounced,bounce_rate"),
                URLQueryItem(name: "order", value: "campaign_name.asc"),
                URLQueryItem(name: "limit", value: "500"),
            ])
            return try JSONDecoder().decode([CampaignTrackingRow].self, from: data)
        }
    }

    /// campaign_leads roster (campaign_id + status). Windowed at `leadsCap`; ordered for
    /// deterministic truncation. Fail-open → (rows: [], ok: false).
    func campaignLeads() async -> (rows: [CampaignLeadRow], ok: Bool) {
        await failOpen {
            let data = try await client.get("campaign_leads", [
                URLQueryItem(name: "select", value: "campaign_id,status"),
                URLQueryItem(name: "order", value: "campaign_id.asc"),
                URLQueryItem(name: "limit", value: "\(Self.leadsCap + 1)"),   // +1 probe row
            ])
            return try JSONDecoder().decode([CampaignLeadRow].self, from: data)
        }
    }

    /// send_queue rows (campaign_id + account + status) for the per-account split.
    /// Windowed at `sendsCap`; ordered for deterministic truncation. Fail-open → (rows: [], ok: false).
    func sendQueueRows() async -> (rows: [SendQueueRow], ok: Bool) {
        await failOpen {
            let data = try await client.get("send_queue", [
                URLQueryItem(name: "select", value: "campaign_id,sending_account,status"),
                URLQueryItem(name: "order", value: "campaign_id.asc"),
                URLQueryItem(name: "limit", value: "\(Self.sendsCap + 1)"),   // +1 probe row
            ])
            return try JSONDecoder().decode([SendQueueRow].self, from: data)
        }
    }

    /// Run a supplementary read; any error logs + yields (rows: [], ok: false) so the
    /// caller can mark the load `partial` (degraded) — distinct from a genuinely empty table.
    private func failOpen<T>(_ body: () async throws -> [T]) async -> (rows: [T], ok: Bool) {
        do { return (try await body(), true) }
        catch {
            NSLog("CampaignsRepository: supplementary read failed (\(error.localizedDescription)); treating as empty")
            return ([], false)
        }
    }
}
