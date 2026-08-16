import Foundation

/// Synthetic lead book for `--fixture`, the dev-only launch mode that boots the
/// REAL window with no Keychain and no network.
///
/// The still harness (`--screenshot`) cannot answer layout questions about the
/// live tab: `ImageRenderer` can't rasterize a `ScrollView`, so every still is
/// rendered through the `staticRender` substitute path. Anything about actual
/// scrolling — where a list starts, whether a column scrolls independently —
/// is invisible to it. This mode closes that gap: same views, same view models,
/// same filter/search code paths, deterministic offline data.
///
/// Synthetic and PII-free by construction: names are generated, not sampled.
enum LeadsFixtureSource {
    static let flag = "--fixture"

    /// The banner the tab shows for as long as this mode is active. A window full
    /// of invented figures that looks exactly like the live one is worse than no
    /// dev mode at all.
    static let banner = "FIXTURE DATA — synthetic leads, not your live book"

    /// DEBUG-ONLY. In a Release build this is always false, whatever is on the
    /// command line, so the signed copy in /Applications cannot be talked into
    /// rendering synthetic numbers by a stale Dock entry or a stray launch argument.
    static var isRequested: Bool {
        #if DEBUG
        return CommandLine.arguments.contains(flag)
        #else
        return false
        #endif
    }

    /// A book big enough to exercise the list cap, every facet menu, and both
    /// lanes. Deterministic: index-derived, no randomness. Rows carry the
    /// `v_cec_leads` shape (axes + booleans) the live decode produces.
    static func inputs(count: Int = 420, now: Date = Date()) -> DashboardInputs {
        let sources = ["sales-nav", "gmaps-leads", "jobsignal", "gmaps-email-discovered"]
        let industries = ["Solar energy company", "Banking", "biotech", "coffee carts",
                          "Plumber", "Financial Services"]
        let places: [(city: String?, state: String?, location: String?)] = [
            ("Tampa", "FL", nil), ("Sacramento", "California", nil), ("Phoenix", "AZ", nil),
            (nil, nil, "Austin, Texas, United States"), (nil, nil, "San Francisco Bay Area"),
            (nil, nil, "London, England, United Kingdom"), (nil, nil, nil),
        ]
        let stages = ["scraped", "researched", "personalized", "campaigned"]

        var leads: [LeadRow] = []
        var replied = Set<String>()
        var sends: [DashboardInputs.SentEvent] = []
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone

        let prefixes = ["Harborline", "Sunfield", "Vellum", "Crestline", "Foothill",
                        "Brightmoor", "Meadowpark"]
        let suffixes = ["Care", "Solar", "Labs", "Motors", "Credit Union", "Studio", "Living"]

        let lastNames = ["Reyes", "Okafor", "Lindqvist", "Marsh", "Ito"]
        for i in 0..<max(1, count) {
            let id = String(format: "fixture-%04d", i)
            let place = places[i % places.count]
            let stage = stages[(i / 3) % stages.count]
            let company = "\(prefixes[i % prefixes.count]) \(suffixes[(i / 7) % suffixes.count]) \(i)"
            // Spread creation over the trend window: ~6 leads per day back from now.
            let created = cal.date(byAdding: .day, value: -(i / 6), to: now) ?? now
            let deep = i % 17 == 0
            let personalized = deep || stage == "personalized" || stage == "campaigned"
            // Every 41st row models the BROKEN write-path invariant: no
            // lead_status row at all (nil axes + the flag), so the offline mode
            // can render the "missing status rows" disclosure the live tab has.
            let missingStatusRow = i % 41 == 40
            leads.append(LeadRow(
                id: id,
                companyName: company,
                firstName: ["Ada", "Bo", "Cy", "Dee", "Eli"][i % 5],
                industry: i % 9 == 0 ? nil : industries[i % industries.count],
                leadSource: sources[i % sources.count],
                city: place.city, state: place.state,
                createdAt: ISO8601DateFormatter().string(from: created),
                outreach: missingStatusRow ? nil
                    : (stage == "campaigned" ? "in_sequence" : "untouched"),
                deepening: missingStatusRow ? nil : (deep ? "in_progress" : "none"),
                personalized: missingStatusRow ? false : personalized,
                hasResearch: missingStatusRow ? false : stage != "scraped",
                statusRowMissing: missingStatusRow,
                // country + search-only columns populated so `--fixture` search
                // exercises the same columns the live query matches (email,
                // last_name, full_name via the parts — QA fixture-gap finding).
                location: place.location,
                country: place.location == nil && place.state == nil ? "US" : nil,
                lastName: lastNames[i % lastNames.count],
                email: "contact\(i)@\(prefixes[i % prefixes.count].lowercased()).example"))
            if stage == "campaigned" && !missingStatusRow {
                if let sentAt = cal.date(byAdding: .day, value: -(i / 6) + 1, to: now) {
                    sends.append(.init(leadID: id, sentAt: ISO8601DateFormatter().string(from: sentAt)))
                }
                if i % 23 == 0 { replied.insert(id) }
            }
        }

        return DashboardInputs(
            leads: leads, totalCount: leads.count, leadsComplete: true,
            repliedLeadIDs: replied, messagedSends: sends)
    }

    /// Offline stand-in for the server search: the same `ilike *term*` semantics
    /// over the fixture book, so the results panel can be driven without network.
    ///
    /// Mirrors the live query's ORDER and LIMIT too, not just its matching — without
    /// them, `--fixture` could never reach the result cap or the "(60+)" suffix,
    /// which are the two behaviours in this panel most likely to be wrong.
    static func search(_ rawTerm: String, in leads: [LeadRow]) -> [LeadRow] {
        guard let term = LeadsRepository.searchTerm(rawTerm)?.lowercased() else { return [] }
        let hits = leads.filter { row in
            [row.companyName, row.fullNameForSearch, row.firstName, row.lastName, row.email]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(term) }
        }
        return Array(LeadsRepository.newestFirst(hits).prefix(LeadsRepository.searchResultLimit))
    }
}
