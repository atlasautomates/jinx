import Foundation

/// A row from `v_cec_leads` — the reader-boundary view the dashboard is scoped
/// to (7.2 remap). Column names match the view DDL in
/// `.claude/migrations/2026-08-16_p7a5_view_semantics_and_probe_v26.sql`.
struct LeadRow: Codable, Identifiable, Sendable {
    let id: String
    let companyName: String?
    let firstName: String?
    let industry: String?
    let leadSource: String?
    let city: String?
    let state: String?
    let createdAt: String?
    // STATUS axes + derived booleans off the view. Axes stay `String?` — a NULL
    // axis means the lead has NO lead_status row (`statusRowMissing`), and
    // coalescing it to a domain-shaped default ("untouched", "none") would
    // assert a state the database never wrote.
    var outreach: String? = nil
    var deepening: String? = nil
    /// Guarded copy of `contracts.is_campaign_ready`'s opener/offer gate — the
    /// view computes it; the app never re-implements the predicate (one-method
    /// ruling).
    var personalized: Bool? = nil
    var hasResearch: Bool? = nil
    var statusRowMissing: Bool? = nil
    // Region inputs (leads-filter). `location` is the LinkedIn free-text form the
    // Sales Navigator path writes INSTEAD of city/state; `country` is the last
    // resort. All optional/defaulted: a select that omits them decodes to nil
    // rather than failing (see `RegionKey`).
    var location: String? = nil
    var country: String? = nil
    // Search-only columns (never selected by the dashboard reads).
    var lastName: String? = nil
    var email: String? = nil
    /// Selected by the search read only: the live query MATCHES on `full_name`,
    /// and 107 live leads carry one that differs from first+last — a hit matched
    /// purely on it must render with a visible reason (view-contract review).
    var fullName: String? = nil

    /// The full-name string search semantics run over: the real column when the
    /// select carried it, else composed from the parts — so the offline search
    /// covers the same columns as the query it stands in for.
    var fullNameForSearch: String? {
        if let full = fullName?.nilIfEmpty { return full }
        let parts = [firstName, lastName].compactMap { $0?.nilIfEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case companyName = "company_name"
        case firstName = "first_name"
        case industry
        case leadSource = "lead_source"
        case city
        case state
        case createdAt = "created_at"
        case outreach
        case deepening
        case personalized
        case hasResearch = "has_research"
        case statusRowMissing = "status_row_missing"
        case location
        case country
        case lastName = "last_name"
        case email
        case fullName = "full_name"
    }
}
