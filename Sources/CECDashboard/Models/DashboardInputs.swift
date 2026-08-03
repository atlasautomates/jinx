import Foundation

/// Everything fetched for one dashboard render. `leads`/`totalCount` are essential
/// (a fetch failure fails the load); every id set below is supplementary (read from
/// a separate table, fail-open to empty → the load is marked `partial`).
struct DashboardInputs: Sendable {
    let leads: [LeadRow]
    let totalCount: Int
    /// True when `leads` IS the whole table (the page walk finished and returned at
    /// least `totalCount` rows). The Leads tab derives its headline figures from the
    /// snapshot only while this holds; otherwise it says "N of M" rather than
    /// presenting a window as a total.
    var leadsComplete: Bool = false
    var tierCounts: [String: Int] = [:]        // lead_enrichment.lead_tier → count
    var sentimentCounts: [String: Int] = [:]   // replies.sentiment → count
    /// EXACT full-table `leads.enrichment_stage` counts (lowercase keys; "unknown" =
    /// NULL). Empty = the exact read failed/unavailable → the builder falls back to
    /// the windowed rollup with its honest scope suffix. Still fed to
    /// `DashboardBuilder` (widget/packer path); the Leads TAB counts stages off the
    /// snapshot instead, so its numbers move with the filter.
    var statusCounts: [String: Int] = [:]
    /// Leads that went through the deep-research lane
    /// (`lead_enrichment.deep_cohort_run_id`).
    var deepLaneLeadIDs: Set<String> = []
    /// Leads with a personalized opener written (`lead_enrichment.personalized_opener`).
    var personalizedLeadIDs: Set<String> = []
    /// DISTINCT leads that replied (`replies.lead_id`). A SET, not a count, so the
    /// reply figure can be intersected with whatever the filter is showing — the
    /// same lead grain as the campaigned-stage count, so the ratio compares like
    /// with like and can't be inflated by multi-reply threads.
    var repliedLeadIDs: Set<String> = []
    /// True when the lane reads failed: `deepLaneLeadIDs`/`personalizedLeadIDs`
    /// being empty is then a READ FAILURE, not a fact about the book, and every lead
    /// would otherwise be misclassified "Not personalized". The lane filter hides
    /// itself rather than offer an answer it cannot compute.
    var lanesDegraded: Bool = false
    /// True when a supplementary read FAILED (vs. genuinely empty) — surfaced in the
    /// UI so degraded data is never mistaken for complete data.
    var partial: Bool = false
    /// Sent emails over the recent window (`send_queue`, `status=sent`,
    /// supplementary, fail-open to empty) — carries `lead_id` so the "messaged /
    /// week" trend can count DISTINCT leads per week (not send steps) and can be
    /// narrowed to the filtered lead set. Bucketing happens in
    /// `ABLeadsData.weeklySeries`.
    var messagedSends: [SentEvent] = []

    /// One sent email: the lead it went to + when it was sent. Value type, Sendable.
    struct SentEvent: Sendable { let leadID: String; let sentAt: String }

    /// Total replied leads — the global tally, for the widget/voice paths that
    /// never filter.
    var replyCount: Int { repliedLeadIDs.count }
}
