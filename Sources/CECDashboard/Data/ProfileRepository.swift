import Foundation

/// The lead profile's read path (7.2 remap): ONE essential read against
/// `v_cec_lead_profile` (the lead + its generated row, pre-joined and
/// jsonb-flattened by the view) plus a fail-open `v_cec_lead_interactions`
/// read for the timeline. Zero LLM calls — deterministic reads + pure compose.
struct ProfileRepository {
    let client: SupabaseClient

    static let interactionsCap = 500

    func fetch(_ ref: LeadRef) async throws -> ProfileInputs {
        // ids ride into eq. filters — strip filter-syntax chars (house pattern).
        let id = Self.sanitized(ref.id)
        guard !id.isEmpty else { throw ProfileError.notFound }
        async let profile = profileRow(id: id)                    // essential
        async let interactions = interactionRows(leadId: id)     // fail-open
        let (lead, enrichment, corrupt) = try await profile
        return Self.compose(lead: lead, enrichment: enrichment,
                            interactions: await interactions,
                            enrichmentCorrupt: corrupt)
    }

    /// Pure packaging seam (SelfTest target): orders the timeline
    /// chronologically by PARSED date (raw ISO string compare breaks on mixed
    /// Z/+00:00 offsets — code review), extracts the LATEST inbound
    /// sentiment/intent, trims a cap+1 fetch to the NEWEST cap rows, and
    /// marks `partial` when the interactions read FAILED (vs. genuinely empty).
    /// The enrichment half can no longer fail independently — it rides the
    /// essential view read; nil means "no generated row yet", a fact not a
    /// failure.
    static func compose(
        lead: LeadDetailRow,
        enrichment: LeadEnrichmentRow?,
        interactions: (rows: [LeadInteractionRow], ok: Bool),
        enrichmentCorrupt: Bool = false
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
            enrichment: enrichment,
            interactions: timeline,
            sentiment: lastInbound?.meta("sentiment"),
            intent: lastInbound?.meta("intent"),
            // A generated half that FAILED TO DECODE is partial — corruption
            // must not render pixel-identically to "never enriched" (delta
            // round 2; the sibling casualized_shape case already surfaces).
            partial: !interactions.ok || enrichmentCorrupt,
            interactionsFailed: !interactions.ok,
            enrichmentCorrupt: enrichmentCorrupt,
            interactionsTruncated: truncated)
    }

    // MARK: - Reads

    /// The whole dossier row. The view's LEFT JOIN returns exactly one row per
    /// existing lead, so "no rows" is genuinely "no such lead". The lead half
    /// and the generated half are two decodes of the SAME response body (each
    /// Codable type reads only its own keys); an all-nil generated half
    /// synthesizes nil so the Personalization card suppresses (7.2 item 12).
    ///
    /// The generated decode is `try?`, deliberately: `research` is a raw
    /// `JSONValue` whose decoder throws past its depth guard, and the view
    /// applies no `jsonb_typeof` guard to that column — one pathological
    /// payload must degrade the ENRICHMENT half to nil, never take down the
    /// contact facts and timeline with it (code review, 7.2).
    private func profileRow(id: String) async throws
        -> (LeadDetailRow, LeadEnrichmentRow?, corrupt: Bool) {
        let data = try await client.get("v_cec_lead_profile", [
            URLQueryItem(name: "select",
                         value: "id,email,first_name,last_name,full_name,company_name,"
                             + "job_title,company_description,location,city,state,"
                             + "phone,website,industry,"
                             + "casualized_first_name,casualized_company_name,"
                             + "casualized_city_name,personalization_project,"
                             + "personalization_detail,personalized_opener,"
                             + "personalized_offer,research,casualized_shape"),
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        guard let lead = try JSONDecoder().decode([LeadDetailRow].self, from: data).first
        else { throw ProfileError.notFound }
        do {
            let generated = try JSONDecoder().decode([LeadEnrichmentRow].self, from: data).first
            return (lead, generated.flatMap { $0.isEmpty ? nil : $0 }, false)
        } catch {
            // Degrade the ENRICHMENT half only — but LOUDLY: log + `partial`,
            // so a corrupt research payload is distinguishable from a lead
            // that was never enriched (delta round 2).
            NSLog("ProfileRepository: generated half failed to decode (dossier partial): %@",
                  error.localizedDescription)
            return (lead, nil, true)
        }
    }

    private func interactionRows(leadId: String) async -> (rows: [LeadInteractionRow], ok: Bool) {
        do {
            // NEWEST-first, cap+1: truncation must shed the OLDEST history
            // (the sentiment badge reads the latest inbound), and the +1 probe
            // distinguishes exactly-cap from over-cap. compose re-sorts
            // ascending for display.
            let data = try await client.get("v_cec_lead_interactions", [
                URLQueryItem(name: "select",
                             value: "id,interaction_type,direction,subject,summary,"
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

    /// `--check-supabase` probe: is `v_cec_lead_interactions` reader-readable at
    /// all? (Grant/shape check via the real select against a nil UUID; expect [].)
    func fetchProbe() async -> Bool {
        await interactionRows(leadId: "00000000-0000-0000-0000-000000000000").ok
    }

    /// `--check-supabase` probe for the dossier view itself: the real select
    /// against a nil UUID must come back 2xx (an empty array), or the profile
    /// sheet is broken for every lead.
    func profileProbe() async -> Bool {
        do {
            _ = try await profileRow(id: "00000000-0000-0000-0000-000000000000")
            return true
        } catch is ProfileError {
            return true    // 2xx, zero rows — the view read itself works
        } catch {
            return false
        }
    }
}

enum ProfileError: LocalizedError {
    case notFound
    var errorDescription: String? { "Lead not found (it may have been removed)." }
}
