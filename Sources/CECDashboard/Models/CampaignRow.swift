import Foundation

// Rows + composed inputs for the Campaigns tab. Column names mirror the Supabase
// schema (.claude/skills/kb/leads-db/schema.sql). All optional — the dashboard
// tolerates missing fields rather than failing a decode.

/// A row from `campaigns`.
struct CampaignRow: Codable, Identifiable {
    let id: String
    let campaignName: String?
    let status: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case campaignName = "campaign_name"
        case status
        case createdAt = "created_at"
    }
}

/// A row from `campaigns_tracking` — pre-aggregated headline metrics, keyed by name
/// (no FK to `campaigns`; joined by campaign_name, 1:1 today).
struct CampaignTrackingRow: Codable {
    let campaignName: String?
    let totalLeads: Int?
    let totalSent: Int?
    let totalReplies: Int?
    let totalBounced: Int?
    let bounceRate: Double?

    enum CodingKeys: String, CodingKey {
        case campaignName = "campaign_name"
        case totalLeads = "total_leads"
        case totalSent = "total_sent"
        case totalReplies = "total_replies"
        case totalBounced = "total_bounced"
        case bounceRate = "bounce_rate"
    }
}

/// A row from `campaign_leads` — the roster + per-lead delivery status. This is the
/// authoritative per-campaign count (campaigns_tracking is a convenience cache).
struct CampaignLeadRow: Codable {
    let campaignId: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case campaignId = "campaign_id"
        case status
    }
}

/// A row from `send_queue` — per-send detail (used for the per-account split).
struct SendQueueRow: Codable {
    let campaignId: String?
    let sendingAccount: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case campaignId = "campaign_id"
        case sendingAccount = "sending_account"
        case status
    }
}

/// Everything the dashboard needs for ONE campaign, composed in the repository from
/// `campaigns` + `campaign_leads` (+ `campaigns_tracking` for sent/replies).
struct CampaignSummary: Identifiable {
    let id: String
    let name: String
    let status: String
    /// campaign_leads.status -> count (pending/sent/replied/bounced/unsubscribed).
    let leadStatusCounts: [String: Int]
    let totalLeads: Int
    let totalSent: Int
    let totalReplies: Int

    /// Reply rate as a WHOLE-NUMBER percentage (per Format `.percent` contract), or nil
    /// when nothing has sent yet. Computed from replies/sent so units are unambiguous.
    var replyRatePercent: Double? {
        guard totalSent > 0 else { return nil }
        return Double(totalReplies) / Double(totalSent) * 100.0
    }
}

/// The full fetched input set for the campaigns dashboard.
struct CampaignInputs {
    let summaries: [CampaignSummary]
    /// sending_account -> count of sent emails (aggregate, from send_queue status='sent').
    let sendsByAccount: [String: Int]
    /// True when the numbers may be INCOMPLETE: a supplementary read failed (RLS/network)
    /// OR a windowed read hit its row cap (so counts under-report). The UI surfaces this
    /// so a degraded/truncated load is never silently shown as authoritative. Default false
    /// keeps existing call sites (e.g. selftest fixtures) working.
    var partial: Bool = false
}

// MARK: - Campaign inspector roster (P4)

/// One `campaign_leads` row for the selected campaign's roster read.
struct CampaignRosterRow: Codable {
    let leadId: String?
    let status: String?
    let addedAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case leadId = "lead_id"
        case addedAt = "added_at"
    }
}

/// A roster row joined with the lead's name/email (left join — a missing
/// `leads` row still renders, falling back to email/"Unknown").
struct CampaignRosterEntry: Identifiable {
    let leadId: String
    let status: String?
    let addedAt: String?
    let companyName: String?
    let email: String?

    var id: String { leadId }
}
