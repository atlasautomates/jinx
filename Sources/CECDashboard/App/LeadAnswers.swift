import Foundation

/// Single source of truth for the spoken-style lead answers shared by the App Intents
/// (Siri surface, `Intents.swift`) and the `--query` CLI (Aris surface, `LeadQuery.swift`),
/// so the two surfaces speak identical data and can't drift. Pure logic over the dashboard
/// read path — the `app-access` skill's "factor answer(for:) so Siri and Aris never drift."
enum LeadAnswers {
    /// Window for source/industry breakdowns. EXACTLY the PostgREST page cap:
    /// any larger value makes the sampled caveat UNREACHABLE — the server caps
    /// every response at 1000 rows regardless of `limit`, so a 2000-row window
    /// could never "saturate" and Siri spoke a 1000-lead window as a whole-book
    /// fact (reliability review, 7.2 — the pinned page-cap learning).
    static let breakdownWindow = 1000

    /// "You have N leads."
    static func count(_ n: Int) -> String { "You have \(n) leads." }

    /// Tally a leads window by a string field. `sampled` compares against the
    /// REAL table total (one cheap HEAD read) — the window size is a floor
    /// either way, and only the total can say whether the window was the book.
    static func breakdownCounts(repo: LeadsRepository,
                                field: (LeadRow) -> String?) async throws -> (counts: [String: Int], sampled: Bool) {
        let leads = try await repo.recentLeads(limit: breakdownWindow)
        let total = try await repo.totalCount()
        var counts: [String: Int] = [:]
        for lead in leads { counts[field(lead)?.nilIfEmpty ?? "Unknown", default: 0] += 1 }
        return (counts, leads.count < total)
    }

    /// "Top <plural>: a with 3, b with 2[ — among the N most recent leads]." or, when the
    /// data is empty, "No <singular> data yet." Top-3 by count desc then key asc; each
    /// label capped so a pathological scraped value can't dominate the utterance.
    static func breakdown(_ counts: [String: Int], singular: String, plural: String,
                          sampled: Bool = false) -> String {
        guard !counts.isEmpty else { return "No \(singular) data yet." }
        let top = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
        let body = top.map { "\($0.key.prefix(40)) with \($0.value)" }.joined(separator: ", ")
        let note = sampled ? " — among the \(breakdownWindow) most recent leads" : ""
        return "Top \(plural): \(body)\(note)."
    }
}
