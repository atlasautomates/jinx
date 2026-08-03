import Foundation

/// Derives ONE region label per lead from the four location columns the scrapers
/// actually populate. Pure, total, locale-stable — every branch is a selftest
/// golden (`regionKeyChecks`).
///
/// Why a derivation and not just `leads.state`: the column is only populated by
/// the Google-Maps-shaped sources. The Sales Navigator path (the majority of the
/// book) writes a LinkedIn free-text `location` instead — "Austin, Texas, United
/// States", "Dallas-Fort Worth Metroplex", "London, England, United Kingdom".
/// Filtering on `state` alone would park ~3 of every 4 leads in one useless
/// bucket, which is the same as having no region filter at all.
///
/// The contract is deliberately conservative: it never GUESSES a state from a
/// city name, and anything it cannot place keeps its own literal label (or
/// `Unknown`) rather than being folded into a neighbour. A region bucket in this
/// app is a filter facet the user reads counts off — a wrong bucket is worse
/// than an honest "Unknown".
enum RegionKey {
    static let unknown = "Unknown"
    static let unitedStates = "United States"

    /// Region label for one lead. Precedence: the explicit `state` column, then
    /// the free-text `location`, then `country`, then `Unknown`.
    static func region(city: String?, state: String?,
                       location: String?, country: String?) -> String {
        if let raw = state?.nilIfEmpty {
            // A populated state column is authoritative. Canonicalize "FL"/"Florida"
            // to one label so the two scraper conventions share a bucket.
            return usState(raw) ?? raw
        }
        // The country column is passed INTO the location parse, not consulted after
        // it: `source-jobsignal` writes location "San Francisco, CA" with country
        // "US" and no state, and a parse that ignores the column falls through to a
        // bucket literally named "CA" sitting beside "California" — the exact split
        // this type exists to prevent (QA found 3 live leads in it).
        if let parsed = fromLocation(location, country: country) { return parsed }
        if let raw = country?.nilIfEmpty {
            return isUSMarker(raw) ? unitedStates : raw
        }
        return unknown
    }

    /// Parse a free-text location, with the row's `country` column as corroborating
    /// evidence for US-state abbreviations. nil when there is nothing to parse.
    static func fromLocation(_ location: String?, country: String? = nil) -> String? {
        guard let raw = location?.nilIfEmpty else { return nil }
        let tokens = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let inUS = tokens.contains(where: isUSMarker)
            || (country?.nilIfEmpty).map(isUSMarker) == true

        // 1. A full US state name anywhere wins — innermost first, so
        //    "Los Angeles County, California, United States" reads California.
        //    Decorations are stripped so "Texas Metropolitan Area" still matches.
        //    EXCEPT the names that are also countries (Georgia): those need US
        //    corroboration, or "Tbilisi, Georgia" silently joins Atlanta's bucket.
        for token in tokens.reversed() {
            guard let state = usStateFullName(undecorated(token)) else { continue }
            if alsoCountryNames.contains(state) && !inUS { continue }
            return state
        }

        // 2. Two-letter abbreviations are only trusted when something says United
        //    States — bare "DE" is Delaware in Maps-shaped data and Germany in
        //    LinkedIn-shaped data, and nothing else disambiguates it.
        if inUS {
            for token in tokens.reversed() {
                if let state = usStateAbbreviation(undecorated(token)) { return state }
            }
            return unitedStates
        }

        // 3. Named metros that carry no state/country token of their own.
        if let mapped = metros[normalizedKey(raw)] { return mapped }

        // 4. LinkedIn's free text ends with the country ("…, Mazowieckie, Poland").
        //    A single unrecognized token keeps its own label — it is usually a
        //    country ("Ireland") and never a fabrication either way.
        guard let last = tokens.last else { return nil }
        // Disambiguate the one name that is both: skipping the state match above is
        // not enough on its own, because the country would then fall through to the
        // IDENTICAL label and land in the same bucket anyway.
        if let state = usStateFullName(undecorated(last)), alsoCountryNames.contains(state) {
            return "\(state) (country)"
        }
        return last
    }

    /// Canonical label for a US state written either way; nil if unrecognized.
    static func usState(_ value: String) -> String? {
        usStateFullName(value) ?? usStateAbbreviation(value)
    }

    private static func usStateFullName(_ value: String) -> String? {
        stateNames[normalizedKey(value)]
    }

    private static func usStateAbbreviation(_ value: String) -> String? {
        let key = normalizedKey(value)
        guard key.count == 2 else { return nil }
        return stateAbbreviations[key]
    }

    /// Case/whitespace-insensitive lookup key (locale-stable lowercasing).
    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Strips the metro/administrative decorations LinkedIn hangs off a place
    /// name so the state inside can still be matched.
    private static func undecorated(_ token: String) -> String {
        var value = normalizedKey(token)
        if value.hasPrefix("greater ") { value = String(value.dropFirst("greater ".count)) }
        for suffix in [" metropolitan area", " metro area", " metroplex",
                       " county", " region", " area"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
            break
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func isUSMarker(_ value: String) -> Bool {
        ["united states", "united states of america", "usa", "us"].contains(normalizedKey(value))
    }

    /// US state names that are also country names. Matching one of these without
    /// US corroboration would merge two different places into one bucket.
    private static let alsoCountryNames: Set<String> = ["Georgia"]

    /// Metros whose own text names neither a state nor a country.
    private static let metros: [String: String] = [
        "san francisco bay area": "California",
        "greater los angeles area": "California",
        "los angeles metropolitan area": "California",
        "greater sacramento": "California",
        "greater san diego area": "California",
        "dallas-fort worth metroplex": "Texas",
        "dallas fort worth metroplex": "Texas",
        "greater houston": "Texas",
        "greater austin": "Texas",
        "greater san antonio": "Texas",
        "greater phoenix area": "Arizona",
        "greater tampa bay area": "Florida",
        "miami-fort lauderdale area": "Florida",
        "greater orlando": "Florida",
        "greater chicago area": "Illinois",
        "greater seattle area": "Washington",
        "greater boston": "Massachusetts",
        "new york city metropolitan area": "New York",
        "greater cambridge area": "United Kingdom",
        "greater london": "United Kingdom",
        "london area, united kingdom": "United Kingdom",
    ]

    private static let stateAbbreviations: [String: String] = [
        "al": "Alabama", "ak": "Alaska", "az": "Arizona", "ar": "Arkansas",
        "ca": "California", "co": "Colorado", "ct": "Connecticut", "de": "Delaware",
        "fl": "Florida", "ga": "Georgia", "hi": "Hawaii", "id": "Idaho",
        "il": "Illinois", "in": "Indiana", "ia": "Iowa", "ks": "Kansas",
        "ky": "Kentucky", "la": "Louisiana", "me": "Maine", "md": "Maryland",
        "ma": "Massachusetts", "mi": "Michigan", "mn": "Minnesota", "ms": "Mississippi",
        "mo": "Missouri", "mt": "Montana", "ne": "Nebraska", "nv": "Nevada",
        "nh": "New Hampshire", "nj": "New Jersey", "nm": "New Mexico", "ny": "New York",
        "nc": "North Carolina", "nd": "North Dakota", "oh": "Ohio", "ok": "Oklahoma",
        "or": "Oregon", "pa": "Pennsylvania", "ri": "Rhode Island", "sc": "South Carolina",
        "sd": "South Dakota", "tn": "Tennessee", "tx": "Texas", "ut": "Utah",
        "vt": "Vermont", "va": "Virginia", "wa": "Washington", "wv": "West Virginia",
        "wi": "Wisconsin", "wy": "Wyoming", "dc": "District of Columbia",
    ]

    /// Full names, keyed by their own normalized form (identity map) so a single
    /// lookup canonicalizes casing too.
    private static let stateNames: [String: String] = {
        var map: [String: String] = [:]
        for name in stateAbbreviations.values {
            map[name.lowercased(with: Locale(identifier: "en_US_POSIX"))] = name
        }
        return map
    }()
}
