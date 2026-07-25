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
    }
}
