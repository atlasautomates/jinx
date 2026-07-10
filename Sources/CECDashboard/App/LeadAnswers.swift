import Foundation

/// Single source of truth for the spoken-style lead answers shared by the App Intents
/// (Siri surface, `Intents.swift`) and the `--query` CLI (Aris surface, `LeadQuery.swift`),
/// so the two surfaces speak identical data and can't drift. Pure logic over the dashboard
/// read path — the `app-access` skill's "factor answer(for:) so Siri and Aris never drift."
enum LeadAnswers {
    /// Window for source/industry breakdowns. A fetch returning this many rows means the
    /// tally is a recency sample (newest leads), not the whole table — callers say so.
    static let breakdownWindow = 2000

    /// "You have N leads."
    static func count(_ n: Int) -> String { "You have \(n) leads." }

    /// Tally a leads window by a string field, reporting whether the window saturated.
    static func breakdownCounts(repo: LeadsRepository,
                                field: (LeadRow) -> String?) async throws -> (counts: [String: Int], sampled: Bool) {
        let leads = try await repo.recentLeads(limit: breakdownWindow)
        var counts: [String: Int] = [:]
        for lead in leads { counts[field(lead)?.nilIfEmpty ?? "Unknown", default: 0] += 1 }
        return (counts, leads.count >= breakdownWindow)
    }

    /// "Top <plural>: a with 3, b with 2[ — among the N most recent leads]." or, when the
    /// data is empty, "No <singular> data yet." Top-3 by count desc then key asc; each
    /// label capped so a pathological scraped value can't dominate the utterance.
    static func breakdown(_ counts: [String: Int], singular: String, plural: String,
                          sampled: Bool = false, incomplete: Bool = false) -> String {
        guard !counts.isEmpty else { return "No \(singular) data yet." }
        let top = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
        let body = top.map { "\($0.key.prefix(40)) with \($0.value)" }.joined(separator: ", ")
        // `sampled` = a recency window (source/industry); `incomplete` = a degraded
        // or floored table read (tier). Different caveats — never claim exactness.
        let note = incomplete ? " — the tally may be incomplete"
            : (sampled ? " — among the \(breakdownWindow) most recent leads" : "")
        return "Top \(plural): \(body)\(note)."
    }
}
