import Foundation

/// Minimal lead identity shared by every profile entry point (Leads list,
/// campaign rosters, Pipeline inspector) — and the pin identity later.
struct LeadRef: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let companyName: String?
    let email: String?
}

/// The profile's rows (same tolerance-first philosophy as the other Row types:
/// only the PK is required; every display field renders a gap when absent).
/// Mirrors `.claude/skills/lead-profile/scripts/lookup_profile.py`'s reads.

struct LeadDetailRow: Codable {
    let id: String
    let email: String?
    let firstName: String?
    let lastName: String?
    let fullName: String?
    let companyName: String?
    let jobTitle: String?
    let companyDescription: String?
    let location: String?
    let city: String?
    let state: String?
    let phone: String?
    let website: String?
    let industry: String?

    enum CodingKeys: String, CodingKey {
        case id, email, location, city, state, phone, website, industry
        case firstName = "first_name"
        case lastName = "last_name"
        case fullName = "full_name"
        case companyName = "company_name"
        case jobTitle = "job_title"
        case companyDescription = "company_description"
    }

    /// Best display name: full name, else first+last, else the email, else "Unknown".
    var displayName: String {
        if let full = fullName?.nilIfEmpty { return full }
        let joined = [firstName, lastName].compactMap { $0?.nilIfEmpty }.joined(separator: " ")
        if !joined.isEmpty { return joined }
        return email?.nilIfEmpty ?? "Unknown"
    }
}

struct LeadEnrichmentRow: Codable {
    let casualizedFirstName: String?
    let casualizedCompanyName: String?
    let casualizedCityName: String?
    let personalizationProject: String?
    let personalizationDetail: String?
    let personalizedOpener: String?
    let personalizedOffer: String?
    let enrichmentSource: String?
    let enrichmentStatus: String?
    let leadTier: String?
    let webResearchJson: JSONValue?

    enum CodingKeys: String, CodingKey {
        case casualizedFirstName = "casualized_first_name"
        case casualizedCompanyName = "casualized_company_name"
        case casualizedCityName = "casualized_city_name"
        case personalizationProject = "personalization_project"
        case personalizationDetail = "personalization_detail"
        case personalizedOpener = "personalized_opener"
        case personalizedOffer = "personalized_offer"
        case enrichmentSource = "enrichment_source"
        case enrichmentStatus = "enrichment_status"
        case leadTier = "lead_tier"
        case webResearchJson = "web_research_json"
    }
}

/// One `lead_interactions` row. NOTE the column is `interaction_type`
/// (verified live), not `type`. `metadata` is free-form jsonb — sentiment and
/// intent live inside it on inbound rows.
struct LeadInteractionRow: Codable {
    let interactionType: String?
    let direction: String?
    let subject: String?
    let summary: String?
    let transcript: String?
    let metadata: JSONValue?
    let source: String?
    let interactionAt: String?

    enum CodingKeys: String, CodingKey {
        case direction, subject, summary, transcript, metadata, source
        case interactionType = "interaction_type"
        case interactionAt = "interaction_at"
    }

    /// String value from the metadata jsonb ("sentiment", "intent", ...).
    /// Production metadata is DOUBLE-ENCODED — a JSON string inside the jsonb
    /// column (QA live finding) — so mirror lookup_profile.py's
    /// json.loads-on-string before reading keys; plain objects still work.
    func meta(_ key: String) -> String? {
        var value = metadata
        if case .string(let s)? = value,
           let data = s.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value = decoded
        }
        guard case .object(let o)? = value, case .string(let s)? = o[key]
        else { return nil }
        return s.nilIfEmpty
    }
}

/// Everything one profile render needs. `lead` is essential; enrichment and
/// interactions are fail-open (missing → sections render a gap + `partial`).
struct ProfileInputs {
    let lead: LeadDetailRow
    let enrichment: LeadEnrichmentRow?
    let interactions: [LeadInteractionRow]
    /// Latest inbound sentiment/intent (parsed from interaction metadata).
    let sentiment: String?
    let intent: String?
    let partial: Bool
    /// The interactions READ failed (distinct from a genuinely empty
    /// conversation) — the view words the empty state honestly.
    let interactionsFailed: Bool
    let interactionsTruncated: Bool
}
