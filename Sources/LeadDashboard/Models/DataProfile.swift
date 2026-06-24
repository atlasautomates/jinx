import Foundation

/// A coarse, slowly-changing fingerprint of the lead data — which widget-relevant
/// series are present and how strong. Drives the layout cache key so the (eventual M2)
/// LLM regenerates only when the data *character* shifts, not on every new lead.
/// Buckets are intentionally coarse so the key stays stable across small data changes.
struct DataProfile: Equatable {
    enum Strength: String, Equatable {
        case none, low, medium, high
    }

    /// series id (bind) → strength bucket.
    let signals: [String: Strength]

    /// Deterministic, process-stable cache key. Do NOT use Swift's `Hashable.hashValue`
    /// here — it's randomized per process and would never match across launches.
    var key: String {
        signals
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.rawValue)" }
            .joined(separator: "|")
    }

    static func from(_ inputs: DashboardInputs) -> DataProfile {
        let leads = inputs.leads
        var s: [String: Strength] = [:]
        // total-leads uses the exact whole-table count; every other leads signal is over
        // the fetched window (recentLeads, capped at 1000) — same window/total split as
        // DashboardBuilder. Past 1000 rows the windowed signals saturate, so magnitude
        // becomes the main key driver; fine for the coarse gate.
        s["total-leads"]   = magnitude(inputs.totalCount)
        s["by-source"]     = distinctness(leads.compactMap { $0.leadSource?.nilIfEmpty })
        s["by-industry"]   = distinctness(leads.compactMap { $0.industry?.nilIfEmpty })
        s["added-weekly"]  = weekSpan(leads)
        s["recent-leads"]  = leads.isEmpty ? Strength.none : Strength.high
        s["location"]      = coverage(leads, present: hasLocation)
        // Supplementary tables (empty if no data / no RLS → strength none → not bound).
        s["by-tier"]       = distinctness(Array(inputs.tierCounts.keys))
        s["sentiment-mix"] = distinctness(Array(inputs.sentimentCounts.keys))
        return DataProfile(signals: s)
    }

    private static func hasLocation(_ lead: LeadRow) -> Bool {
        if lead.city?.nilIfEmpty != nil { return true }
        if lead.state?.nilIfEmpty != nil { return true }
        return false
    }

    // MARK: - Coarse buckets (deliberately wide so the key changes slowly)

    private static func magnitude(_ n: Int) -> Strength {
        if n < 1 { return .none }
        if n < 100 { return .low }
        if n < 1000 { return .medium }
        return .high
    }

    private static func distinctness(_ values: [String]) -> Strength {
        switch Set(values).count {
        case 0: return .none
        case 1: return .low
        case 2...3: return .medium
        default: return .high
        }
    }

    private static func weekSpan(_ leads: [LeadRow]) -> Strength {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let weeks = Set(leads.compactMap { lead -> Int? in
            guard let d = DateParse.iso(lead.createdAt) else { return nil }
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
        })
        switch weeks.count {
        case 0: return .none
        case 1...2: return .low
        case 3...6: return .medium
        default: return .high
        }
    }

    private static func coverage(_ leads: [LeadRow], present: (LeadRow) -> Bool) -> Strength {
        guard !leads.isEmpty else { return .none }
        let frac = Double(leads.filter(present).count) / Double(leads.count)
        if frac < 0.01 { return .none }
        if frac < 0.25 { return .low }
        if frac < 0.75 { return .medium }
        return .high
    }
}
