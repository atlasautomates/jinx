import Foundation
import Observation

/// Drill state for the Campaigns tab: level 1 (campaign list, owned by
/// `CampaignDashboardViewModel`) → level 2 (one campaign's leads) → level 3
/// (one lead's correspondence). Successor of `CampaignInspectorModel`, keeping
/// its invariants: newest-wins generation guard around every await, header and
/// rows cleared in the same synchronous step, selection by id never index.
/// Strictly read-only.
@MainActor
@Observable
final class CampaignDrillModel {
    // Level 2 — selected campaign + its roster.
    private(set) var campaign: CampaignSummary?
    private(set) var roster: [CampaignRosterEntry] = []
    private(set) var rosterTruncated = false
    private(set) var namesDegraded = false
    private(set) var isLoadingRoster = false
    private(set) var rosterMessage: String?

    // Level 3 — selected lead + the correspondence timeline.
    private(set) var lead: CampaignRosterEntry?
    private(set) var thread: [CorrespondenceItem] = []
    private(set) var interactionsFailed = false
    private(set) var queueFailed = false
    private(set) var threadTruncated = false
    private(set) var queueTruncated = false
    private(set) var isLoadingThread = false
    private(set) var threadMessage: String?

    private var generation = 0

    init() {}

    /// Preview-harness/fixture path: preloaded state, no network. Lives here so
    /// the harness renders the REAL root view rather than a styled twin.
    init(fixtureCampaign: CampaignSummary?,
         roster: [CampaignRosterEntry],
         lead: CampaignRosterEntry? = nil,
         thread: [CorrespondenceItem] = []) {
        self.campaign = fixtureCampaign
        self.roster = roster
        self.lead = lead
        self.thread = thread
    }

    /// Drill into a campaign: shows level 2 and loads its roster.
    func openCampaign(_ summary: CampaignSummary) async {
        generation += 1
        let mine = generation
        // Header, rows, and the deeper level change together — never the new
        // campaign's name over the old campaign's leads.
        campaign = summary
        clearLead()
        roster = []
        rosterTruncated = false
        namesDegraded = false
        rosterMessage = nil
        isLoadingRoster = true
        defer { if mine == generation { isLoadingRoster = false } }
        do {
            let repo = CampaignsRepository(client: try SupabaseClient.make())
            let result = try await repo.roster(campaignId: summary.id)
            guard mine == generation else { return }   // superseded
            roster = result.entries
            rosterTruncated = result.truncated
            namesDegraded = result.namesDegraded
            if result.entries.isEmpty {
                rosterMessage = "No leads enrolled in this campaign."
            }
        } catch {
            guard mine == generation else { return }   // superseded
            roster = []
            rosterMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Drill into a lead: shows level 3 and loads the correspondence timeline.
    func openLead(_ entry: CampaignRosterEntry) async {
        guard let campaign else { return }   // level 3 needs a campaign context
        generation += 1
        let mine = generation
        lead = entry
        thread = []
        interactionsFailed = false
        queueFailed = false
        threadTruncated = false
        queueTruncated = false
        threadMessage = nil
        isLoadingThread = true
        defer { if mine == generation { isLoadingThread = false } }
        do {
            let repo = CampaignsRepository(client: try SupabaseClient.make())
            let result = await repo.correspondence(campaignId: campaign.id,
                                                   leadId: entry.leadId)
            guard mine == generation else { return }   // superseded
            apply(result)
        } catch {
            guard mine == generation else { return }   // superseded
            thread = []
            threadMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func apply(_ result: (items: [CorrespondenceItem], interactionsOK: Bool,
                                  queueOK: Bool, truncated: Bool, queueTruncated: Bool)) {
        thread = result.items
        interactionsFailed = !result.interactionsOK
        queueFailed = !result.queueOK
        threadTruncated = result.truncated
        queueTruncated = result.queueTruncated
        if !result.interactionsOK && !result.queueOK {
            threadMessage = "Couldn't load correspondence — both reads failed."
        } else if result.items.isEmpty {
            threadMessage = "No correspondence with this lead yet."
        } else {
            threadMessage = nil
        }
    }

    /// Refresh the CURRENT drill level in place — no clearing, no spinner, so
    /// the 10-minute tick and the header refresh can keep rows honest without
    /// resetting scroll or teleporting the user (review: the header refreshed
    /// live while the rows beneath it silently aged). Generation-guarded:
    /// results only apply if the user hasn't navigated meanwhile. At level 3
    /// the roster is refreshed too, so the lead's status pill re-resolves.
    func refreshLevel() async {
        guard let campaign else { return }   // level 1 owns its own refresh
        let mine = generation
        guard let client = try? SupabaseClient.make() else { return }
        let repo = CampaignsRepository(client: client)

        if let lead {
            async let rosterTask = try? repo.roster(campaignId: campaign.id)
            async let threadTask = repo.correspondence(campaignId: campaign.id,
                                                       leadId: lead.leadId)
            let rosterResult = await rosterTask
            let threadResult = await threadTask
            guard mine == generation else { return }   // superseded
            if let rosterResult {
                roster = rosterResult.entries
                rosterTruncated = rosterResult.truncated
                namesDegraded = rosterResult.namesDegraded
                // Re-resolve the lead snapshot so its status pill stays live.
                if let fresh = rosterResult.entries.first(where: { $0.leadId == lead.leadId }) {
                    self.lead = fresh
                }
            }
            // A BACKGROUND refresh must never trade a populated timeline for a
            // both-reads-failed blank (delta review) — that's openLead's
            // prerogative, not the 10-minute tick's. Partial failure still
            // applies (it degrades with captions, not to empty).
            if !(!threadResult.interactionsOK && !threadResult.queueOK) {
                apply(threadResult)
            }
        } else {
            guard let result = try? await repo.roster(campaignId: campaign.id) else { return }
            guard mine == generation else { return }   // superseded
            roster = result.entries
            rosterTruncated = result.truncated
            namesDegraded = result.namesDegraded
            rosterMessage = result.entries.isEmpty
                ? "No leads enrolled in this campaign." : nil
        }
    }

    // MARK: - Staged-copy revision (the app's one write path)

    private(set) var isSavingRevision = false
    /// Error from the last save attempt (cleared on the next attempt/success).
    private(set) var revisionError: String?

    /// Clear a stale save error — called when an editor opens, so a failure
    /// from one card/lead can never render under another's fresh editor.
    func clearRevisionError() { revisionError = nil }

    /// True while the revision editor is open (maintained by the view). The
    /// root's Esc handler consults it: Esc must never pop a level out from
    /// under an open editor — that destroys the draft with no confirmation
    /// (delta review). The editor's own Cancel is the way out.
    private(set) var isEditorOpen = false
    func setEditorOpen(_ open: Bool) { isEditorOpen = open }

    /// Post a copy revision for one staged send, then reload the timeline so
    /// the card shows what the database now holds (never an optimistic echo).
    /// Returns true on success (the editor closes on true).
    func saveRevision(queueId: String, subject: String?, body: String?) async -> Bool {
        guard !isSavingRevision, let lead else { return false }
        let savedLeadId = lead.leadId
        isSavingRevision = true
        revisionError = nil
        defer { isSavingRevision = false }
        do {
            let writer = try SupabaseWriteClient.make()
            try await writer.updateStagedCopy(queueId: queueId, subject: subject, body: body)
            // Reload keyed to LEAD IDENTITY, not the generation: the reload's
            // question is "is the user looking at the row I changed?" — true
            // even if they popped out and drilled back into the same lead
            // while the write was in flight (review).
            if let current = self.lead, current.leadId == savedLeadId {
                await openLead(current)
            }
            return true
        } catch {
            guard self.lead?.leadId == savedLeadId else { return false }   // navigated away
            revisionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // The row moved on (claimed/sent): reload so the stale "Staged"
            // card snaps to reality instead of inviting a retry loop. Error
            // set FIRST and preserved — openLead doesn't touch revisionError.
            if case SupabaseWriteClient.WriteError.rowNotEditable = error,
               let current = self.lead {
                await openLead(current)
            }
            return false
        }
    }

    /// Breadcrumb: back to the campaign list. Bumps the generation so any
    /// in-flight roster/thread load is superseded and can't repopulate a level
    /// the user just left.
    func popToCampaigns() {
        generation += 1
        campaign = nil
        roster = []
        rosterTruncated = false
        namesDegraded = false
        rosterMessage = nil
        isLoadingRoster = false
        clearLead()
    }

    /// Breadcrumb: back to the campaign's lead list.
    func popToLeads() {
        generation += 1
        isLoadingThread = false
        clearLead()
    }

    private func clearLead() {
        lead = nil
        thread = []
        interactionsFailed = false
        queueFailed = false
        threadTruncated = false
        queueTruncated = false
        threadMessage = nil
        isLoadingThread = false
        revisionError = nil   // a save error must not follow the user to another lead
    }
}
