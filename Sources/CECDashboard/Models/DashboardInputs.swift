import Foundation

/// Everything fetched for one dashboard render. `leads`/`totalCount` are essential
/// (a fetch failure fails the load); `tierCounts`/`sentimentCounts` are supplementary
/// (read from separate tables, fail-open to empty → their widgets simply don't appear).
struct DashboardInputs {
    let leads: [LeadRow]
    let totalCount: Int
    var tierCounts: [String: Int] = [:]        // lead_enrichment.lead_tier → count
    var sentimentCounts: [String: Int] = [:]   // replies.sentiment → count
    /// EXACT full-table `leads.enrichment_stage` counts (lowercase keys; "unknown" =
    /// NULL). Empty = the exact read failed/unavailable → the builder falls back to
    /// the windowed rollup with its honest scope suffix.
    var statusCounts: [String: Int] = [:]
    /// True when a supplementary read FAILED (vs. genuinely empty) — surfaced in a
    /// widget title so degraded data is never mistaken for complete data.
    var partial: Bool = false
}
