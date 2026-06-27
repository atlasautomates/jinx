import Foundation

/// Everything fetched for one dashboard render. `leads`/`totalCount` are essential
/// (a fetch failure fails the load); `tierCounts`/`sentimentCounts` are supplementary
/// (read from separate tables, fail-open to empty → their widgets simply don't appear).
struct DashboardInputs {
    let leads: [LeadRow]
    let totalCount: Int
    var tierCounts: [String: Int] = [:]        // lead_enrichment.lead_tier → count
    var sentimentCounts: [String: Int] = [:]   // replies.sentiment → count
}
