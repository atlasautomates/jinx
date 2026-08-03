import Foundation

/// A row from the `leads` table — the subset the dashboard reads.
/// Column names match `.claude/shared/supabase_client.py` (the schema contract).
struct LeadRow: Codable, Identifiable, Sendable {
    let id: String
    let companyName: String?
    let firstName: String?
    let industry: String?
    let leadSource: String?
    let city: String?
    let state: String?
    let createdAt: String?
    // Pipeline position (P5-3): scraped/campaigned/… Defaulted so the memberwise
    // init keeps working for existing fixtures (decode still reads the column).
    var enrichmentStage: String? = nil
    // Region inputs (leads-filter). `location` is the LinkedIn free-text form the
    // Sales Navigator path writes INSTEAD of city/state; `country` is the last
    // resort. All optional/defaulted: a select that omits them decodes to nil
    // rather than failing (see `RegionKey`).
    var location: String? = nil
    var country: String? = nil
    // Search-only columns (never selected by the dashboard reads).
    var lastName: String? = nil
    var email: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case companyName = "company_name"
        case firstName = "first_name"
        case industry
        case leadSource = "lead_source"
        case city
        case state
        case createdAt = "created_at"
        case enrichmentStage = "enrichment_stage"
        case location
        case country
        case lastName = "last_name"
        case email
    }
}
