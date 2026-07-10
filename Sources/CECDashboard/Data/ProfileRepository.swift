import Foundation

/// The lead profile's 3-table read (mirrors the lead-profile skill's
/// `lookup_profile.py`): `leads` is essential; `lead_enrichment` and
/// `lead_interactions` fail open so a missing row/policy degrades to a
/// partial dossier, never a blank sheet. Zero LLM calls — deterministic
/// reads + pure compose.
struct ProfileRepository {
    let client: SupabaseClient

    static let interactionsCap = 500

    func fetch(_ ref: LeadRef) async throws -> ProfileInputs {
        // ids ride into eq. filters — strip filter-syntax chars (house pattern).
        let id = Self.sanitized(ref.id)
        guard !id.isEmpty else { throw ProfileError.notFound }
        async let lead = leadDetail(id: id)                       // essential
        async let enrichment = enrichmentRow(leadId: id)          // fail-open
        async let interactions = interactionRows(leadId: id)     // fail-open
        return Self.compose(lead: try await lead,
                            enrichment: await enrichment,
                            interactions: await interactions)
    }

    /// Pure packaging seam (SelfTest target): orders the timeline
    /// chronologically by PARSED date (raw ISO string compare breaks on mixed
    /// Z/+00:00 offsets — code review), extracts the LATEST inbound
    /// sentiment/intent, trims a cap+1 fetch to the NEWEST cap rows, and
    /// marks `partial` when a supplementary read FAILED (vs. genuinely empty).
    static func compose(
        lead: LeadDetailRow,
        enrichment: (row: LeadEnrichmentRow?, ok: Bool),
        interactions: (rows: [LeadInteractionRow], ok: Bool)
    ) -> ProfileInputs {
        var timeline = interactions.rows.sorted {
            (DateParse.iso($0.interactionAt) ?? .distantPast)
                < (DateParse.iso($1.interactionAt) ?? .distantPast)
        }
        // The fetch asks for cap+1 NEWEST rows; over-cap means truncation, and
        // trimming drops the OLDEST extras — the sentiment badge must always
        // see the true latest inbound (reliability review).
        let truncated = timeline.count > interactionsCap
        if truncated { timeline = Array(timeline.suffix(interactionsCap)) }
        let lastInbound = timeline.last {
            ($0.direction ?? "").lowercased() == "inbound"
        }
        return ProfileInputs(
            lead: lead,
            enrichment: enrichment.row,
            interactions: timeline,
            sentiment: lastInbound?.meta("sentiment"),
            intent: lastInbound?.meta("intent"),
            partial: !enrichment.ok || !interactions.ok,
            interactionsFailed: !interactions.ok,
            interactionsTruncated: truncated)
    }

    // MARK: - Reads

    private func leadDetail(id: String) async throws -> LeadDetailRow {
        let data = try await client.get("leads", [
            URLQueryItem(name: "select",
                         value: "id,email,first_name,last_name,full_name,company_name,"
                             + "job_title,company_description,location,city,state,"
                             + "phone,website,industry"),
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        guard let row = try JSONDecoder().decode([LeadDetailRow].self, from: data).first
        else { throw ProfileError.notFound }
        return row
    }

    private func enrichmentRow(leadId: String) async -> (row: LeadEnrichmentRow?, ok: Bool) {
        do {
            let data = try await client.get("lead_enrichment", [
                URLQueryItem(name: "select",
                             value: "casualized_first_name,casualized_company_name,"
                                 + "casualized_city_name,personalization_project,"
                                 + "personalization_detail,personalized_opener,"
                                 + "personalized_offer,enrichment_source,"
                                 + "enrichment_status,lead_tier,web_research_json"),
                URLQueryItem(name: "lead_id", value: "eq.\(leadId)"),
                URLQueryItem(name: "limit", value: "1"),
            ])
            return (try JSONDecoder().decode([LeadEnrichmentRow].self, from: data).first, true)
        } catch {
            NSLog("ProfileRepository: enrichment read failed (partial dossier): %@",
                  error.localizedDescription)
            return (nil, false)
        }
    }

    private func interactionRows(leadId: String) async -> (rows: [LeadInteractionRow], ok: Bool) {
        do {
            // NEWEST-first, cap+1: truncation must shed the OLDEST history
            // (the sentiment badge reads the latest inbound), and the +1 probe
            // distinguishes exactly-cap from over-cap. compose re-sorts
            // ascending for display.
            let data = try await client.get("lead_interactions", [
                URLQueryItem(name: "select",
                             value: "interaction_type,direction,subject,summary,"
                                 + "transcript,metadata,source,interaction_at"),
                URLQueryItem(name: "lead_id", value: "eq.\(leadId)"),
                URLQueryItem(name: "order", value: "interaction_at.desc"),
                URLQueryItem(name: "limit", value: "\(Self.interactionsCap + 1)"),
            ])
            return (try JSONDecoder().decode([LeadInteractionRow].self, from: data), true)
        } catch {
            NSLog("ProfileRepository: interactions read failed (timeline omitted): %@",
                  error.localizedDescription)
            return ([], false)
        }
    }

    static func sanitized(_ id: String) -> String {
        String(id.unicodeScalars.filter { !",()\"\\ ".unicodeScalars.contains($0) })
    }

    /// `--check-supabase` probe: is `lead_interactions` anon-readable at all?
    /// (RLS/shape check via the real select against a nil UUID; expect [].)
    func fetchProbe() async -> Bool {
        await interactionRows(leadId: "00000000-0000-0000-0000-000000000000").ok
    }
}

enum ProfileError: LocalizedError {
    case notFound
    var errorDescription: String? { "Lead not found (it may have been removed)." }
}
