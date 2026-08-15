import Foundation

/// The healing-backlog scan (P6). The bucket counts + enrollment exclusion
/// mirror `ce doctor`'s `check_dead_ends` EXACTLY (live-verified 497/299
/// parity); the cohort breakdown is this board's own cross-reason view
/// (ce.py keeps per-reason cohorts for its heal plan). Semantics:
/// - Enrollment scan of `campaign_leads` FAILS CLOSED (throws → board
///   unavailable): rendering dead-end counts on an unfiltered set is the
///   display twin of the healer's wasted-spend bug.
/// - Dead-end scan of `v_campaign_ready` warns-and-continues on truncation
///   (an under-count is honest when labeled a floor).
/// - Leads enrolled in ANY campaign are excluded in compose; the excluded
///   count is surfaced, never silent.
struct BacklogRepository {
    let client: SupabaseClient

    /// Page budgets: 20k enrollment rows / 10k flagged rows — same ceilings
    /// as ce.py. PostgREST caps every response at 1000 regardless of limit.
    static let enrollmentMaxPages = 20
    static let deadEndMaxPages = 10

    func fetch() async throws -> BacklogInputs {
        // Sequential on purpose: if enrollment fails or truncates, DON'T
        // spend the dead-end reads (fail-closed ordering, like ce.py).
        let enrolled = try await enrolledLeadIds()
        if enrolled.isEmpty {
            // RLS-invisibility guard (reliability review): PostgREST returns
            // 200+[] when a role has no SELECT policy — indistinguishable from
            // an empty table. Campaigns existing with ZERO enrollments anywhere
            // is not a real state, so treat it as a denied read, fail closed.
            if (try? await client.count("campaigns")) ?? 0 > 0 {
                throw BacklogError.enrollmentUnreadable
            }
        }
        if enrolled.count > 15_000 {
            NSLog("BacklogRepository: enrollment scan at %d rows — approaching the "
                + "20k client-scan ceiling; move exclusion server-side before it hits",
                  enrolled.count)
        }
        let (flagged, truncated) = try await flaggedRows()
        if flagged.isEmpty {
            // False-all-clear guard: if anon can't see `leads`, the
            // security_invoker view goes silently empty too. leads being
            // readable (count > 0) makes an empty flagged set trustworthy.
            // The count THROWS on transport failure (delta review): a network
            // blip must surface as a generic recoverable error, not the
            // definitive "no leads readable" verdict.
            if try await client.count("leads") == 0 {
                throw BacklogError.viewUnreadable
            }
        }
        return Self.compose(flagged: flagged, enrolled: enrolled,
                            scanTruncated: truncated)
    }

    /// Cheap readability probe for `--check-supabase` (platform review: the
    /// diagnostic must not run the full paged scan inside its 20s wall —
    /// it needs to prove the tables are readable, not tally them).
    func readProbe() async -> Bool {
        do {
            // v_campaign_ready was DROPPED at 5.1 (one-method ruling): the
            // eligibility question is answered ONLY by Python's
            // contracts.is_campaign_ready. The backlog listing below still
            // targets the dropped view and shows its error state until the
            // 7.2 dashboard remap feeds it from the one method's output.
            _ = try await client.get("campaign_leads", [
                URLQueryItem(name: "select", value: "lead_id"),
                URLQueryItem(name: "limit", value: "1"),
            ])
            return true
        } catch { return false }
    }

    /// Pure seam (SelfTest target): generic bucketing over every returned
    /// reason, CROSS-REASON cohort tallies with ce.py's ("?", "?") fallbacks,
    /// enrollment exclusion + excluded count.
    static func compose(flagged: [CampaignReadyRow], enrolled: Set<String>,
                        scanTruncated: Bool) -> BacklogInputs {
        var byReason: [String: Int] = [:]
        var cohortCounts: [CohortKey: Int] = [:]
        var alreadyEnrolled = 0

        for row in flagged {
            if let id = row.leadId, enrolled.contains(id) {
                alreadyEnrolled += 1
                continue
            }
            let reason = row.blockingReason?.nilIfEmpty ?? "?"
            byReason[reason, default: 0] += 1
            let key = CohortKey(source: row.leadSource?.nilIfEmpty ?? "?",
                                query: row.searchQuery?.nilIfEmpty ?? "?")
            cohortCounts[key, default: 0] += 1
        }

        let cohorts = cohortCounts
            .map { (key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count
                    : ($0.key.source, $0.key.query) < ($1.key.source, $1.key.query) }
            .map { BacklogCohort(source: $0.key.source, query: $0.key.query, count: $0.count) }

        return BacklogInputs(byReason: byReason, cohorts: cohorts,
                             alreadyEnrolled: alreadyEnrolled,
                             scanTruncated: scanTruncated)
    }

    // MARK: - Reads

    /// Every lead enrolled in any campaign. THROWS on error OR truncation —
    /// an incomplete exclusion set must abort the board, not under-exclude.
    private func enrolledLeadIds() async throws -> Set<String> {
        var ids = Set<String>()
        var offset = 0
        for _ in 0..<Self.enrollmentMaxPages {
            let data = try await client.get("campaign_leads", [
                URLQueryItem(name: "select", value: "lead_id"),
                URLQueryItem(name: "order", value: "lead_id"),
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
            let page = try JSONDecoder().decode([EnrolledRow].self, from: data)
            ids.formUnion(page.compactMap(\.leadId))
            if page.count < 1000 { return ids }
            offset += page.count
        }
        throw BacklogError.enrollmentTruncated
    }

    /// All flagged rows from v_campaign_ready, paged; truncation at the page
    /// budget is tolerated (flag, don't fail — under-reporting is safe).
    private func flaggedRows() async throws -> (rows: [CampaignReadyRow], truncated: Bool) {
        var rows: [CampaignReadyRow] = []
        var offset = 0
        for _ in 0..<Self.deadEndMaxPages {
            let data = try await client.get("v_campaign_ready", [
                URLQueryItem(name: "select",
                             value: "lead_id,lead_source,search_query,blocking_reason"),
                URLQueryItem(name: "blocking_reason", value: "not.is.null"),
                URLQueryItem(name: "order", value: "lead_id"),
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
            let page = try JSONDecoder().decode([CampaignReadyRow].self, from: data)
            rows.append(contentsOf: page)
            if page.count < 1000 { return (rows, false) }
            offset += page.count
        }
        return (rows, true)
    }

    private struct EnrolledRow: Codable {
        let leadId: String?
        enum CodingKeys: String, CodingKey { case leadId = "lead_id" }
    }
}

enum BacklogError: LocalizedError {
    case enrollmentTruncated
    case enrollmentUnreadable
    case viewUnreadable

    var errorDescription: String? {
        switch self {
        case .enrollmentTruncated:
            return "Backlog unavailable — the enrollment scan exceeded its page "
                + "budget; dead-end counts must never render on an unfiltered set."
        case .enrollmentUnreadable:
            return "Backlog unavailable — campaigns exist but zero enrollments "
                + "are readable; the campaign_leads anon policy looks missing."
        case .viewUnreadable:
            return "Backlog unavailable — no leads are readable, so an empty "
                + "dead-end scan can't be trusted (anon read policies missing?)."
        }
    }
}
