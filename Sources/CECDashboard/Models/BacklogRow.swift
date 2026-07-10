import Foundation

/// One flagged lead from `v_campaign_ready` (blocking_reason IS NOT NULL).
struct CampaignReadyRow: Codable {
    let leadId: String?
    let leadSource: String?
    let searchQuery: String?
    let blockingReason: String?

    enum CodingKeys: String, CodingKey {
        case leadId = "lead_id"
        case leadSource = "lead_source"
        case searchQuery = "search_query"
        case blockingReason = "blocking_reason"
    }
}

/// The composed backlog: bucket counts + per-cohort breakdown, AFTER the
/// enrollment exclusion (a lead already in any campaign is not a dead end —
/// mirrors `ce doctor`'s check_dead_ends exactly).
struct BacklogInputs {
    /// blocking_reason → count, over WHATEVER reasons the view returned
    /// (never a hardcoded bucket list — new reasons must not vanish).
    let byReason: [String: Int]
    /// (lead_source, search_query) cohorts with counts, largest first.
    let cohorts: [BacklogCohort]
    /// Flagged leads excluded because they're enrolled in a campaign.
    let alreadyEnrolled: Int
    /// The dead-end scan stopped at its page budget — counts are a floor.
    let scanTruncated: Bool
}

struct BacklogCohort: Hashable {
    let source: String
    let query: String
    let count: Int
}

/// Collision-free cohort key (code review: a literal `|` in source/query
/// would conflate two cohorts under a joined-string key — ce.py uses a tuple).
struct CohortKey: Hashable {
    let source: String
    let query: String
}
