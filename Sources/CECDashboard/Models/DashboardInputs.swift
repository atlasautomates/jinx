import Foundation

/// Everything fetched for one dashboard render. `leads`/`totalCount` are essential
/// (a fetch failure fails the load); the replied set and the sent-event log are
/// supplementary (read from the other reader views, fail-open to empty → the load
/// is marked `partial`).
///
/// The lane/personalization id sets that used to live here are gone (7.2 remap):
/// lane classification now rides the lead rows themselves (`deepening`,
/// `personalized` off `v_cec_leads`), so it is essential by construction and can
/// no longer fail independently of the book.
struct DashboardInputs: Sendable {
    let leads: [LeadRow]
    let totalCount: Int
    /// True when `leads` IS the whole table (the page walk finished and returned at
    /// least `totalCount` rows). The Leads tab derives its headline figures from the
    /// snapshot only while this holds; otherwise it says "N of M" rather than
    /// presenting a window as a total.
    var leadsComplete: Bool = false
    /// DISTINCT leads with an inbound interaction (`v_cec_lead_interactions`,
    /// direction=inbound). A SET, not a count, so the reply figure can be
    /// intersected with whatever the filter is showing — the same lead grain as
    /// the emailed count, so the ratio compares like with like and can't be
    /// inflated by multi-reply threads.
    var repliedLeadIDs: Set<String> = []
    /// True when a supplementary read FAILED (vs. genuinely empty) — surfaced in the
    /// UI so degraded data is never mistaken for complete data.
    var partial: Bool = false
    /// WHICH reads failed, in user-facing words ("replies", "outreach history").
    /// A bare `partial` flag was not enough: a failed replies read renders
    /// pixel-identically to a book with no replies, and a failed sent-events read
    /// draws a confident flat-zero outreach trend. The UI names what is understated.
    var degradedReads: [String] = []
    /// Every outbound campaign email on record (`v_cec_sent_events` — the
    /// janitor-proof permanent log; supplementary, fail-open to empty). Carries
    /// `lead_id` so the "messaged / week" trend can count DISTINCT leads per week
    /// (not send steps), the emailed KPI can count DISTINCT leads ever reached,
    /// and both can be narrowed to the filtered lead set. Bucketing happens in
    /// `ABLeadsData.weeklySeries`.
    var messagedSends: [SentEvent] = []

    /// One sent email: the lead it went to + when it was sent. Value type, Sendable.
    struct SentEvent: Sendable { let leadID: String; let sentAt: String }

    /// Total replied leads — the global tally, for the widget/voice paths that
    /// never filter.
    var replyCount: Int { repliedLeadIDs.count }
}
