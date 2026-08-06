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

// MARK: - Correspondence drill-down (level 3)

/// A full `send_queue` row for one (campaign, lead) — the staged/sent/failed
/// per-step detail behind the correspondence timeline. `subject_override` /
/// `body_override` are the VIP per-lead copy; for pool sends the copy lives in
/// `campaign_sequences`, which the dashboard's anon key cannot read.
struct SendQueueDetailRow: Codable {
    let id: String
    let stepNumber: Int?
    let variantIndex: Int?
    let sendingAccount: String?
    /// pending / sending (claimed or delivered-awaiting-recovery) / sent /
    /// failed / skipped — plus the composed synthetic "bounced" (a failed row
    /// whose send WAS archived: handle_bounce flips sent→failed post-delivery).
    let status: String?
    let scheduledAt: String?
    let sentAt: String?
    let toEmail: String?
    let error: String?
    let subjectOverride: String?
    let bodyOverride: String?

    enum CodingKeys: String, CodingKey {
        case id, status, error
        case stepNumber = "step_number"
        case variantIndex = "variant_index"
        case sendingAccount = "sending_account"
        case scheduledAt = "scheduled_at"
        case sentAt = "sent_at"
        case toEmail = "to_email"
        case subjectOverride = "subject_override"
        case bodyOverride = "body_override"
    }
}

/// One entry in a lead's correspondence timeline: either an archived interaction
/// (`lead_interactions` — inbound reply or outbound send, with body text) or a
/// `send_queue` row that has no archived copy (staged/failed/skipped, or a sent
/// row predating the interaction archive).
struct CorrespondenceItem: Identifiable {
    enum Kind {
        /// Archived email (lead_interactions): `direction` distinguishes in/out.
        case interaction
        /// Queue row with no archived interaction: status carries pending/failed/….
        case queued
    }

    let id: String
    let kind: Kind
    /// The `send_queue` primary key for queued rows — the revision editor's
    /// PATCH target. nil for interactions.
    let queueId: String?
    /// "inbound" / "outbound" for interactions; nil for queued rows.
    let direction: String?
    /// send_queue.status for queued rows (pending/failed/skipped/sent); nil otherwise.
    let queueStatus: String?
    let subject: String?
    /// Email text (interaction transcript, else summary; queued rows only when a
    /// VIP body_override exists). nil = genuinely unavailable, never "".
    let body: String?
    /// True when this is outbound copy whose template lives in
    /// `campaign_sequences` (not anon-readable) — the UI says so instead of
    /// rendering an empty bubble.
    let bodyUnreadable: Bool
    let stepNumber: Int?
    let variantIndex: Int?
    let sendingAccount: String?
    let toEmail: String?
    let error: String?
    /// Parsed event time: interaction_at, or sent_at ?? scheduled_at for queue
    /// rows. nil sorts to the timeline start (unknown-when, shown dateless).
    let date: Date?
    /// Raw timestamp string for display (the parsed `date` drives ordering).
    let timestamp: String?
    /// True when the interaction's metadata names a DIFFERENT campaign than the
    /// one being drilled into (the timeline shows the lead's whole history).
    let fromOtherCampaign: Bool

    /// Staged = queued and still waiting to send.
    var isStaged: Bool {
        kind == .queued && (queueStatus ?? "").lowercased() == "pending"
    }
}
