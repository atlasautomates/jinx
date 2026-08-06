import Foundation

/// Read-only queries for the Campaigns tab. Mirrors `LeadsRepository`: typed rows via
/// the shared `SupabaseClient` (GET-only, anon key). The roster (`campaign_leads`) is
/// the source of truth; `campaigns_tracking` supplies headline sent/reply numbers.
struct CampaignsRepository {
    let client: SupabaseClient

    /// Page budget for the full campaign_leads sweep: 11 pages × ≤1000 rows.
    /// PostgREST caps EVERY response at 1000 rows regardless of `limit`, so
    /// windowed single reads cannot detect their own truncation — paging with
    /// short-page termination is the only honest read (same rationale as
    /// `roster()`; the pre-review version asked for 10001 rows and its
    /// truncation probe could mathematically never fire — review finding).
    private static let leadsMaxPages = 11

    /// Fetch + compose everything the dashboard needs. `campaigns` is essential (a
    /// throw fails the load); the rest fail-open so a missing table/RLS/network blip
    /// degrades gracefully (empty funnels) instead of blanking the whole tab — but the
    /// resulting `partial` flag tells the UI the numbers may be incomplete.
    func fetch() async throws -> CampaignInputs {
        async let campaignsTask = campaigns()                 // essential
        async let trackingTask = tracking()                   // fail-open
        async let leadsTask = campaignLeads()                 // fail-open

        let campaigns = try await campaignsTask
        let (tracking, trackingOK) = await trackingTask
        let (leadRows, leadsOK, leadsTruncated) = await leadsTask

        let degraded = !trackingOK || !leadsOK || leadsTruncated
        if leadsTruncated {
            NSLog("%@", "CampaignsRepository: campaign_leads paging budget spent at \(leadRows.count) rows; counts may under-report")
        }

        return Self.compose(
            campaigns: campaigns, tracking: tracking,
            leadRows: leadRows, partial: degraded
        )
    }

    /// Pure composition of raw rows → dashboard inputs. No I/O, so it's unit-testable
    /// (see SelfTest) and the network path above stays a thin wrapper.
    static func compose(
        campaigns: [CampaignRow],
        tracking: [CampaignTrackingRow],
        leadRows: [CampaignLeadRow],
        partial: Bool
    ) -> CampaignInputs {
        // Roster status counts per campaign_id.
        var statusByCampaign: [String: [String: Int]] = [:]
        for row in leadRows {
            guard let cid = row.campaignId else { continue }
            let status = (row.status?.nilIfEmpty ?? "unknown").lowercased()
            statusByCampaign[cid, default: [:]][status, default: 0] += 1
        }
        // Roster total per campaign (authoritative count).
        let rosterTotal: [String: Int] = statusByCampaign.mapValues { $0.values.reduce(0, +) }

        // Tracking headline numbers, joined to campaigns by NORMALIZED name (trim + case-
        // fold) — there's no FK, so a stray space or case difference would otherwise drop
        // the join and silently fall back to roster counts.
        let trackingByName: [String: CampaignTrackingRow] = Dictionary(
            tracking.compactMap { row in normalizeName(row.campaignName).map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )

        let summaries: [CampaignSummary] = campaigns.map { c in
            let displayName = c.campaignName?.nilIfEmpty ?? "Untitled campaign"
            let counts = statusByCampaign[c.id] ?? [:]
            // Only join tracking for campaigns that actually have a name — otherwise two
            // unnamed campaigns would both key to "untitled" and share one tracking row.
            let key = normalizeName(c.campaignName)
            let track = key.flatMap { trackingByName[$0] }

            // Bind sent + replies to ONE source so the reply-rate ratio is internally
            // consistent: tracking (provider-aggregated) when matched, else the roster
            // (campaign_leads.status) — never one metric from each.
            let sent: Int
            let replies: Int
            if let track {
                sent = track.totalSent ?? 0
                replies = track.totalReplies ?? 0
            } else {
                sent = counts["sent", default: 0]
                replies = counts["replied", default: 0]
                if key != nil {
                    // "%@" form: displayName is DB-sourced — never format-position it (CWE-134).
                    NSLog("%@", "CampaignsRepository: no tracking row for '\(displayName)'; using roster counts")
                }
            }
            let total = rosterTotal[c.id] ?? track?.totalLeads ?? counts.values.reduce(0, +)
            return CampaignSummary(
                id: c.id,
                name: displayName,
                status: c.status?.nilIfEmpty ?? "unknown",
                leadStatusCounts: counts,
                totalLeads: total,
                totalSent: sent,
                totalReplies: replies
            )
        }
        // Order preserved from `campaigns` (already created_at desc, newest first).
        return CampaignInputs(summaries: summaries, partial: partial)
    }

    /// Trim + case-fold a campaign name for joining; nil/blank → nil (won't key a join).
    static func normalizeName(_ name: String?) -> String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }

    // MARK: - Campaign inspector roster (P4)

    /// Runaway bound on roster paging: 10 pages × ≤1000 rows.
    static let rosterMaxPages = 10

    /// The selected campaign's full roster, newest-added first, joined with
    /// lead names/emails. The roster read is ESSENTIAL (throws → the detail
    /// pane shows the error); the name join fails open (a miss renders
    /// email/"Unknown", never fails the roster). Paged with empty-page
    /// termination (PostgREST caps responses at 1000 regardless of limit).
    func roster(campaignId: String) async throws
        -> (entries: [CampaignRosterEntry], truncated: Bool, namesDegraded: Bool) {
        let id = ProfileRepository.sanitized(campaignId)
        guard !id.isEmpty else { return ([], false, false) }

        var rows: [CampaignRosterRow] = []
        var offset = 0
        var complete = false
        for _ in 0..<Self.rosterMaxPages {
            let data = try await client.get("campaign_leads", [
                URLQueryItem(name: "select", value: "lead_id,status,added_at"),
                URLQueryItem(name: "campaign_id", value: "eq.\(id)"),
                URLQueryItem(name: "order", value: "added_at.desc,lead_id.asc"),
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
            let page = try JSONDecoder().decode([CampaignRosterRow].self, from: data)
            rows.append(contentsOf: page)
            // A SHORT page proves exhaustion (code review: empty-only left a
            // short final page on the last iteration flagged as truncated).
            // Only "every page full, budget spent" stays ambiguous → flagged.
            if page.count < 1000 { complete = true; break }
            offset += page.count
        }

        let (names, namesOK) = await leadNames(ids: rows.compactMap(\.leadId))
        return (Self.composeRoster(rows: rows, names: names), !complete, !namesOK)
    }

    /// Pure left-join seam (SelfTest target): roster order preserved; rows
    /// with no `leads` match keep nil name/email; nil lead_ids are dropped
    /// (they can't open a profile and shouldn't render a dead row). Duplicate
    /// lead_ids dedupe to the FIRST (newest under the sort) occurrence —
    /// offset paging over a moving newest-first set can re-serve a row, and
    /// `CampaignRosterEntry.id == leadId` feeds ForEach identity (review).
    static func composeRoster(rows: [CampaignRosterRow],
                              names: [String: LeadSearchHit]) -> [CampaignRosterEntry] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let leadId = row.leadId?.nilIfEmpty,
                  seen.insert(leadId).inserted else { return nil }
            let hit = names[leadId]
            return CampaignRosterEntry(leadId: leadId,
                                       status: row.status,
                                       addedAt: row.addedAt,
                                       companyName: hit?.companyName,
                                       email: hit?.email)
        }
    }

    /// Names/emails for the roster's lead ids — fail-open + chunked in.()
    /// (150 UUIDs/request keeps URLs far from any proxy limit). `ok: false`
    /// when any chunk failed, so the view can caption the degradation instead
    /// of rendering indistinguishable "Unknown" rows (reliability review).
    private func leadNames(ids: [String]) async -> (byId: [String: LeadSearchHit], ok: Bool) {
        let unique = Array(Set(ids.map(ProfileRepository.sanitized)))
            .filter { !$0.isEmpty }
        guard !unique.isEmpty else { return ([:], true) }
        var byId: [String: LeadSearchHit] = [:]
        var ok = true
        for chunk in stride(from: 0, to: unique.count, by: 150)
            .map({ Array(unique[$0..<min($0 + 150, unique.count)]) }) {
            do {
                let data = try await client.get("leads", [
                    URLQueryItem(name: "select", value: "id,company_name,email"),
                    URLQueryItem(name: "id", value: "in.(\(chunk.joined(separator: ",")))"),
                ])
                for hit in try JSONDecoder().decode([LeadSearchHit].self, from: data) {
                    byId[hit.id] = hit
                }
            } catch {
                ok = false
                NSLog("CampaignsRepository.leadNames chunk failed (rows fall back to email/Unknown): %@",
                      error.localizedDescription)
            }
        }
        return (byId, ok)
    }

    // MARK: - Correspondence (drill-down level 3)

    /// Newest-history cap on the interactions read (same shape as the profile
    /// timeline: cap+1 newest-first probe, trimmed to the newest `cap`).
    static let correspondenceCap = 500
    /// Queue rows per (campaign, lead): sequences are ≤ a handful of steps, so
    /// 200 is a runaway bound, not a window we expect to fill.
    static let queueCap = 200

    /// Everything said (and staged to be said) between our accounts and one lead.
    /// Both reads fail open INDIVIDUALLY so one bad table degrades to a captioned
    /// half-timeline; the caller treats both-failed as an error state.
    ///
    /// - `lead_interactions` is lead-scoped (no campaign column) — the timeline
    ///   deliberately shows the lead's whole history, flagging rows whose
    ///   metadata names a different campaign.
    /// - `send_queue` is scoped to (campaign, lead).
    func correspondence(campaignId: String, leadId: String) async
        -> (items: [CorrespondenceItem], interactionsOK: Bool, queueOK: Bool,
            truncated: Bool, queueTruncated: Bool) {
        let cid = ProfileRepository.sanitized(campaignId)
        let lid = ProfileRepository.sanitized(leadId)
        guard !cid.isEmpty, !lid.isEmpty else { return ([], false, false, false, false) }

        async let interactionsTask = interactionRows(leadId: lid)
        async let queueTask = queueRows(campaignId: cid, leadId: lid)
        let (interactions, interactionsOK) = await interactionsTask
        let (queue, queueOK) = await queueTask

        let queueTruncated = queue.count > Self.queueCap
        let (items, truncated) = Self.composeCorrespondence(
            campaignId: cid, interactions: interactions,
            queue: queueTruncated ? Array(queue.prefix(Self.queueCap)) : queue)
        return (items, interactionsOK, queueOK, truncated, queueTruncated)
    }

    /// Fuzzy-dedupe window for legacy sent rows whose interaction archive
    /// predates queue_id stamping: same step, timestamps within this many
    /// seconds → treat as the same email.
    static let legacyDedupeWindow: TimeInterval = 180

    /// Pure merge seam (SelfTest target). Rules:
    /// - Interactions become timeline entries with body = transcript ?? summary.
    ///   Identity = the row's PRIMARY KEY (selected by the fetch); a fetch-index
    ///   fallback exists only for rows that somehow arrive without one.
    /// - A cap+1 interactions fetch is trimmed to the NEWEST `correspondenceCap`
    ///   rows (they arrive newest-first); returns `truncated` alongside the items
    ///   so exactly one place owns that predicate.
    /// - Queue rows whose send was archived (an interaction's metadata carries
    ///   the same queue_id) dedupe out when `sent` — the archived copy is richer.
    ///   A `failed` row whose id IS archived means bounced-after-delivery
    ///   (handle_bounce flips sent→failed): it renders as a distinct "bounced"
    ///   entry, never a generic Failed that implies it was never sent.
    /// - Legacy `sent` rows whose archive predates queue_id stamping fuzzy-dedupe
    ///   by (step_number, |Δt| < legacyDedupeWindow) against outbound interactions.
    /// - Everything else renders: pending = staged, sending in-flight,
    ///   failed/skipped labeled, unarchived sent rows as compact entries.
    /// - Sorted ascending by parsed date (nil dates first); ties break on id —
    ///   stable across refreshes now that interaction ids are PK-derived.
    static func composeCorrespondence(
        campaignId: String,
        interactions: [LeadInteractionRow],
        queue: [SendQueueDetailRow]
    ) -> (items: [CorrespondenceItem], truncated: Bool) {
        let truncated = interactions.count > correspondenceCap
        let trimmed = truncated
            ? Array(interactions.prefix(correspondenceCap))   // newest-first fetch
            : interactions

        let archivedQueueIds = Set(trimmed.compactMap { $0.meta("queue_id") })
        // (step, date) index of outbound archives for the legacy fuzzy dedupe.
        let outboundArchives: [(step: Int?, date: Date?)] = trimmed
            .filter { ($0.direction ?? "").lowercased() == "outbound" }
            .map { ($0.meta("step_number").flatMap(Int.init), DateParse.iso($0.interactionAt)) }

        var items: [CorrespondenceItem] = []
        for (index, row) in trimmed.enumerated() {
            let metaCampaign = row.meta("campaign_id")
            items.append(CorrespondenceItem(
                id: "int-\(row.id?.nilIfEmpty ?? "idx-\(index)")",
                kind: .interaction,
                queueId: nil,
                direction: row.direction?.lowercased().nilIfEmpty,
                queueStatus: nil,
                subject: row.subject?.nilIfEmpty,
                body: row.transcript?.nilIfEmpty ?? row.summary?.nilIfEmpty,
                // ce-outbound archives sends subject-only (no transcript) —
                // the copy is the sequence template the anon key can't read.
                bodyUnreadable: (row.transcript?.nilIfEmpty
                    ?? row.summary?.nilIfEmpty) == nil
                    && (row.direction ?? "").lowercased() == "outbound",
                stepNumber: row.meta("step_number").flatMap(Int.init),
                variantIndex: row.meta("variant_index").flatMap(Int.init),
                sendingAccount: row.meta("sending_account"),
                toEmail: nil,
                error: nil,
                date: DateParse.iso(row.interactionAt),
                timestamp: row.interactionAt,
                fromOtherCampaign: metaCampaign != nil && metaCampaign != campaignId))
        }
        for row in queue {
            var status = (row.status ?? "").lowercased()
            let archived = archivedQueueIds.contains(row.id)
            if status == "sent" {
                if archived { continue }   // the archived interaction is the record
                // Legacy: archive predates queue_id stamping — fuzzy-match on
                // (step, time) so one email doesn't render twice.
                let sentDate = DateParse.iso(row.sentAt)
                let isLegacyDuplicate = outboundArchives.contains { archive in
                    guard let step = archive.step, let rowStep = row.stepNumber,
                          let at = archive.date, let sent = sentDate else { return false }
                    return step == rowStep && abs(at.timeIntervalSince(sent)) < Self.legacyDedupeWindow
                }
                if isLegacyDuplicate { continue }
            }
            // Bounced-after-delivery: handle_bounce flips sent→failed AFTER the
            // interaction archived. Label it as the distinct thing it is.
            if status == "failed" && archived { status = "bounced" }
            items.append(CorrespondenceItem(
                id: "sq-\(row.id)",
                kind: .queued,
                queueId: row.id,
                direction: nil,
                queueStatus: status.nilIfEmpty ?? "unknown",
                subject: row.subjectOverride?.nilIfEmpty,
                body: row.bodyOverride?.nilIfEmpty,
                bodyUnreadable: row.bodyOverride?.nilIfEmpty == nil,
                stepNumber: row.stepNumber,
                variantIndex: row.variantIndex,
                sendingAccount: row.sendingAccount?.nilIfEmpty,
                toEmail: row.toEmail?.nilIfEmpty,
                error: row.error?.nilIfEmpty,
                date: DateParse.iso(row.sentAt) ?? DateParse.iso(row.scheduledAt),
                timestamp: row.sentAt?.nilIfEmpty ?? row.scheduledAt,
                fromOtherCampaign: false))
        }

        let sorted = items.sorted {
            let l = $0.date ?? .distantPast, r = $1.date ?? .distantPast
            return l == r ? $0.id < $1.id : l < r
        }
        return (sorted, truncated)
    }

    /// `lead_interactions` for one lead, newest first, cap+1 probe. Selects the
    /// PK for stable timeline identity; secondary id sort makes equal-timestamp
    /// pages deterministic. Fail-open.
    private func interactionRows(leadId: String) async -> (rows: [LeadInteractionRow], ok: Bool) {
        await failOpen {
            let data = try await client.get("lead_interactions", [
                URLQueryItem(name: "select",
                             value: "id,interaction_type,direction,subject,summary,"
                                 + "transcript,metadata,source,interaction_at"),
                URLQueryItem(name: "lead_id", value: "eq.\(leadId)"),
                URLQueryItem(name: "order", value: "interaction_at.desc,id.desc"),
                URLQueryItem(name: "limit", value: "\(Self.correspondenceCap + 1)"),
            ])
            return try JSONDecoder().decode([LeadInteractionRow].self, from: data)
        }
    }

    /// `send_queue` rows for one (campaign, lead), step order, cap+1 probe
    /// (caller trims and captions overflow). Fail-open.
    private func queueRows(campaignId: String, leadId: String) async
        -> (rows: [SendQueueDetailRow], ok: Bool) {
        await failOpen {
            let data = try await client.get("send_queue", [
                URLQueryItem(name: "select",
                             value: "id,step_number,variant_index,sending_account,"
                                 + "status,scheduled_at,sent_at,to_email,error,"
                                 + "subject_override,body_override"),
                URLQueryItem(name: "campaign_id", value: "eq.\(campaignId)"),
                URLQueryItem(name: "lead_id", value: "eq.\(leadId)"),
                URLQueryItem(name: "order", value: "step_number.asc,id.asc"),
                URLQueryItem(name: "limit", value: "\(Self.queueCap + 1)"),
            ])
            return try JSONDecoder().decode([SendQueueDetailRow].self, from: data)
        }
    }

    // MARK: - Table reads

    /// All campaigns, newest first.
    func campaigns() async throws -> [CampaignRow] {
        let data = try await client.get("campaigns", [
            URLQueryItem(name: "select", value: "id,campaign_name,status,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        return try JSONDecoder().decode([CampaignRow].self, from: data)
    }

    /// campaigns_tracking headline metrics. Fail-open → (rows: [], ok: false).
    func tracking() async -> (rows: [CampaignTrackingRow], ok: Bool) {
        await failOpen {
            let data = try await client.get("campaigns_tracking", [
                URLQueryItem(name: "select",
                             value: "campaign_name,total_leads,total_sent,total_replies,total_bounced,bounce_rate"),
                URLQueryItem(name: "order", value: "campaign_name.asc"),
                URLQueryItem(name: "limit", value: "500"),
            ])
            return try JSONDecoder().decode([CampaignTrackingRow].self, from: data)
        }
    }

    /// campaign_leads roster (campaign_id + status), PAGED at 1000/page with
    /// short-page termination (PostgREST caps every response at 1000 regardless
    /// of `limit`). `truncated` = page budget spent with every page full.
    /// Fail-open → (rows: [], ok: false, truncated: false).
    func campaignLeads() async -> (rows: [CampaignLeadRow], ok: Bool, truncated: Bool) {
        do {
            var rows: [CampaignLeadRow] = []
            var offset = 0
            for _ in 0..<Self.leadsMaxPages {
                let data = try await client.get("campaign_leads", [
                    URLQueryItem(name: "select", value: "campaign_id,status"),
                    // Secondary sort key makes offset pages deterministic.
                    URLQueryItem(name: "order", value: "campaign_id.asc,lead_id.asc"),
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "offset", value: String(offset)),
                ])
                let page = try JSONDecoder().decode([CampaignLeadRow].self, from: data)
                rows.append(contentsOf: page)
                if page.count < 1000 { return (rows, true, false) }   // short page = exhausted
                offset += page.count
            }
            return (rows, true, true)   // budget spent, every page full → may under-report
        } catch {
            NSLog("%@", "CampaignsRepository: campaign_leads read failed (\(error.localizedDescription)); treating as empty")
            return ([], false, false)
        }
    }

    /// Run a supplementary read; any error logs + yields (rows: [], ok: false) so the
    /// caller can mark the load `partial` (degraded) — distinct from a genuinely empty table.
    private func failOpen<T>(_ body: () async throws -> [T]) async -> (rows: [T], ok: Bool) {
        do { return (try await body(), true) }
        catch {
            // "%@" form: error text can carry % tokens (percent-encoded URLs) — CWE-134.
            NSLog("%@", "CampaignsRepository: supplementary read failed (\(error.localizedDescription)); treating as empty")
            return ([], false)
        }
    }
}
