import Foundation

/// Minimal lead identity shared by every profile entry point (Leads list, search
/// hits, pinned strip) — and the pin identity later.
struct LeadRef: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let companyName: String?
    let email: String?
}

/// The profile's rows (same tolerance-first philosophy as the other Row types:
/// only the PK is required; every display field renders a gap when absent).
/// Both decode from ONE `v_cec_lead_profile` read (7.2 remap) — the view is a
/// LEFT JOIN of the lead and its generated row, so the lead half and the
/// generated half are two decodes of the same response.

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

/// The GENERATED half of the profile view (`lead_generated` via the LEFT JOIN):
/// casualized values, personalization, opener/offer, research. The view
/// flattens the jsonb columns (with `jsonb_typeof` guards, so corrupt shapes
/// read as absent) — the app never re-parses them.
struct LeadEnrichmentRow: Codable {
    let casualizedFirstName: String?
    let casualizedCompanyName: String?
    let casualizedCityName: String?
    let personalizationProject: String?
    let personalizationDetail: String?
    let personalizedOpener: String?
    let personalizedOffer: String?
    let research: JSONValue?
    /// `jsonb_typeof(casualized)` from the view — p7a5 exposes it so a
    /// corrupted casualized payload (a string scalar where an object belongs)
    /// is VISIBLE rather than rendering identically to "never casualized".
    let casualizedShape: String?

    enum CodingKeys: String, CodingKey {
        case casualizedFirstName = "casualized_first_name"
        case casualizedCompanyName = "casualized_company_name"
        case casualizedCityName = "casualized_city_name"
        case personalizationProject = "personalization_project"
        case personalizationDetail = "personalization_detail"
        case personalizedOpener = "personalized_opener"
        case personalizedOffer = "personalized_offer"
        case research
        case casualizedShape = "casualized_shape"
    }

    /// True when every generated field is absent. The LEFT JOIN returns a row
    /// for EVERY lead — a lead with no `lead_generated` row decodes to all-nil
    /// here, and presenting that as "an enrichment exists" would render an empty
    /// Personalization card. The repository synthesizes nil instead (7.2 item 12).
    var isEmpty: Bool {
        !hasPersonalizationContent && research == nil && !casualizedCorrupt
    }

    /// True when the PERSONALIZATION CARD has something to show: any casualized
    /// value, personalization fact, opener, or offer that survives a whitespace
    /// trim. A research-only lead (the pipeline's most common intermediate
    /// state) has an enrichment row but NO card content — rendering the card
    /// for it produced an empty fact grid (QA finding, 7.2). Blank-string
    /// openers count as absent, matching the view's own btrim predicate.
    var hasPersonalizationContent: Bool {
        [casualizedFirstName, casualizedCompanyName, casualizedCityName,
         personalizationProject, personalizationDetail,
         personalizedOpener, personalizedOffer]
            .contains { $0?.nilIfEmpty != nil }
    }

    /// The casualized jsonb exists but is not an object — corrupt, not absent.
    var casualizedCorrupt: Bool {
        guard let shape = casualizedShape else { return false }
        return shape != "object"
    }
}

/// One `v_cec_lead_interactions` row. NOTE the column is `interaction_type`
/// (verified live), not `type`. `metadata` is free-form jsonb — sentiment and
/// intent live inside it on inbound rows.
struct LeadInteractionRow: Codable {
    /// Primary key — stable timeline identity + the replied-set keyset cursor.
    let id: String?
    let interactionType: String?
    let direction: String?
    let subject: String?
    let summary: String?
    let transcript: String?
    let metadata: JSONValue?
    let source: String?
    let interactionAt: String?

    enum CodingKeys: String, CodingKey {
        case id, direction, subject, summary, transcript, metadata, source
        case interactionType = "interaction_type"
        case interactionAt = "interaction_at"
    }

    /// String value from the metadata jsonb ("sentiment", "intent", ...).
    /// Production metadata is DOUBLE-ENCODED — a JSON string inside the jsonb
    /// column (QA live finding) — so mirror lookup_profile.py's
    /// json.loads-on-string before reading keys; plain objects still work.
    /// JSON NUMBERS also surface (integer-formatted): ce-outbound writes
    /// step_number/variant_index as numbers, and a string-only reader renders
    /// them nil forever (QA adversarial driver, 2026-08-05).
    func meta(_ key: String) -> String? {
        var value = metadata
        if case .string(let s)? = value,
           let data = s.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value = decoded
        }
        guard case .object(let o)? = value else { return nil }
        switch o[key] {
        case .string(let s)?:
            return s.nilIfEmpty
        case .number(let d)?:
            // Same integer rendering as JSONValue.render (no trailing .0).
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        default:
            return nil
        }
    }
}

/// Everything one profile render needs. `lead` is essential; enrichment rides
/// the same essential read (nil = no generated row yet) and interactions are
/// fail-open (missing → the timeline renders a gap + `partial`).
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
    /// The generated half FAILED TO DECODE (distinct from "never enriched") —
    /// its own flag so the partial banner can name BOTH causes when both
    /// fail, instead of blaming whichever one it checked first.
    let enrichmentCorrupt: Bool
    let interactionsTruncated: Bool
}
