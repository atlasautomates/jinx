import Foundation

/// Showcase lead book for `--demo`, the DEBUG-only launch mode for portfolio
/// screenshots (#113). It boots the real window over fictional SOLAR companies,
/// with no Keychain and no network.
///
/// How it differs from `LeadsFixtureSource` (`--fixture`): that book is a
/// layout-QA set built to break things (a 420-row mixed-industry book with
/// deliberately broken status rows, inert rows, throwaway pins, a red banner).
/// This one is built to be looked at. It is a plausible single-vertical book,
/// most fields are filled and some are deliberately blank (a real scrape is
/// never complete), every row opens a synthetic dossier with an interaction
/// timeline, and pins persist in a demo-only file so a screenshot session can
/// set up its pinned strip once.
///
/// Fictional by construction: company names are generated from word lists,
/// domains use the reserved `.example` TLD, and phone numbers sit in the
/// 555-0100…0199 fiction block. `--selftest` asserts both.
enum DemoBook {
    static let flag = "--demo"

    /// The quiet header pill. It's honest without dominating a screenshot,
    /// unlike the fixture's red banner, which exists to stop a developer
    /// mistaking synthetic numbers for live ones.
    static let notice = "Sample data"

    /// DEBUG-only, like `--fixture`: a Release build never renders the demo book.
    /// `--fixture` wins if both flags are passed.
    static var isRequested: Bool {
        #if DEBUG
        return CommandLine.arguments.contains(flag) && !LeadsFixtureSource.isRequested
        #else
        return false
        #endif
    }

    /// Demo pins live beside, never inside, the real store: the real pin file
    /// would render live leads above the demo book.
    static func pinsDirectory() -> URL {
        PinsStore.defaultDirectory().deletingLastPathComponent()
            .appendingPathComponent("CECDashboard-demo", isDirectory: true)
    }

    static let count = 160

    /// One clock for the whole session: the list and every dossier derive their
    /// dates from the same instant, so a window left open never shows a lead
    /// list older than the profiles behind it.
    static let anchor = Date()

    // MARK: - Word lists

    private static let prefixes = [
        "Copperleaf", "Saguaro Ridge", "Tidewater", "Blue Heron", "Juniper Flats",
        "Amberline", "Brightwater", "Lone Pine", "Sundial", "Clearsky",
        "Goldcrest", "Redrock", "Palmetto Grove", "Silver Mesa", "High Noon",
        "Cedar Hollow",
    ]
    private static let suffixes = [
        "Solar", "Solar & Roofing", "Energy", "Solar Co.", "Power Systems",
        "Renewables", "Solar Electric", "Sun Works", "Energy Solutions",
        "Solar + Storage",
    ]
    private static let industries: [String?] = [
        "Solar energy company", "Solar panel installer", "Solar energy system service",
        "Solar energy company", "Solar energy equipment supplier", "Renewable energy",
        "Solar panel installer", "Roofing contractor", "Electrician", nil,
    ]
    /// (city, state, sales-nav free-text location, area code). Mixed shapes on
    /// purpose: Maps scrapes write city/state; Sales Navigator writes a
    /// free-text location instead; a few rows have neither.
    private static let places: [(String?, String?, String?, String)] = [
        ("Phoenix", "AZ", nil, "602"), ("Tucson", "AZ", nil, "520"),
        ("Las Vegas", "NV", nil, "702"), ("San Diego", "CA", nil, "619"),
        ("Sacramento", "CA", nil, "916"), ("Fresno", "CA", nil, "559"),
        ("Austin", "TX", nil, "512"), ("San Antonio", "TX", nil, "210"),
        ("Houston", "TX", nil, "713"), ("Tampa", "FL", nil, "813"),
        ("Orlando", "FL", nil, "407"), ("Fort Myers", "FL", nil, "239"),
        ("Denver", "CO", nil, "303"), ("Albuquerque", "NM", nil, "505"),
        ("Salt Lake City", "UT", nil, "801"), ("Raleigh", "NC", nil, "919"),
        ("Charleston", "SC", nil, "843"),
        (nil, nil, "Greater Phoenix Area", "480"),
        (nil, nil, "Dallas-Fort Worth Metroplex", "214"),
        (nil, nil, "Greater Los Angeles Area", "213"),
        (nil, nil, nil, "800"),
    ]
    private static let firstNames = [
        "Marisol", "Grant", "Priya", "Owen", "Tessa", "Luis", "Hannah", "Darnell",
        "Keiko", "Brett", "Alana", "Victor", "Jolene", "Samir", "Corinne", "Wade",
        "Nadia", "Elliot", "Rosa", "Trent", "Imani", "Calvin", "Yesenia", "Dale",
    ]
    private static let lastNames = [
        "Alvarez", "Whitfield", "Nair", "Castellano", "Brooks", "Okonkwo", "Lund",
        "Delgado", "Harrow", "Kimura", "Pratt", "Esposito", "Vance", "Haddad",
        "Mercer", "Quintana", "Sorensen", "Tillman", "Abernathy", "Fujii",
    ]
    private static let sources = ["gmaps-leads", "gmaps-leads", "sales-nav", "gmaps-leads",
                                  "jobsignal", "gmaps-email-discovered"]
    private static let titles: [String?] = ["Owner", "Founder & CEO", "Operations Manager",
                                            "Sales Director", "Co-Owner", nil, "General Manager"]
    private static let projects = [
        "commercial rooftop arrays", "battery backup installs", "EV charger add-ons",
        "ground-mount systems for ranches", "solar carports", "HOA-approved panel layouts",
        "off-grid cabin builds", "re-roof + solar bundles",
    ]
    /// (personalization detail, opener). Paired so each opener follows from
    /// its own fact. Opener args: short company name, project, count.
    private static let details: [(String, String)] = [
        ("%d installs posted in their project gallery",
         "Saw %@'s work on %@. %d installs in the gallery is a lot of quoting to keep up with."),
        ("4.8 stars across %d Google reviews",
         "Saw %@'s work on %@. Holding a 4.8 across %d Google reviews takes real follow-through."),
        ("%d open quotes mentioned in a hiring post",
         "Saw %@ is hiring to keep up with %@. %d open quotes is a lot to chase by hand."),
        ("%d systems commissioned last year per their site",
         "Saw %@'s work on %@. %d systems commissioned last year means a busy quoting desk."),
    ]
    private static let offers = [
        "We follow up every open quote automatically, with a 5-email sequence that "
            + "brings the homeowners who went quiet back to the table.",
        "Missed calls get an instant text-back with a booking link, so after-hours "
            + "leads don't go to the next installer on Google.",
        "After each install we send an automated review request, which turns finished "
            + "jobs into the 5-star reviews your next customer reads first.",
    ]

    // MARK: - Book

    /// Deterministic: everything is index-derived and anchored to `now`.
    static func inputs(now: Date = anchor) -> DashboardInputs {
        var leads: [LeadRow] = []
        var replied = Set<String>()
        var sends: [DashboardInputs.SentEvent] = []
        for i in 0..<count {
            let s = spec(i, now: now)
            leads.append(s.row)
            for send in s.sendDates {
                sends.append(.init(leadID: s.row.id, sentAt: iso(send)))
            }
            if s.replied { replied.insert(s.row.id) }
        }
        return DashboardInputs(leads: leads, totalCount: leads.count, leadsComplete: true,
                               repliedLeadIDs: replied, messagedSends: sends)
    }

    /// The dossier behind a demo row, or nil for an id outside the book.
    static func profile(for id: String, now: Date = anchor) -> ProfileInputs? {
        guard id.hasPrefix("demo-"), let i = Int(id.dropFirst(5)), (0..<count).contains(i)
        else { return nil }
        let s = spec(i, now: now)
        return ProfileRepository.compose(lead: s.detail, enrichment: s.enrichment,
                                         interactions: (s.interactions, true))
    }

    // MARK: - One lead

    private struct Spec {
        let row: LeadRow
        let detail: LeadDetailRow
        let enrichment: LeadEnrichmentRow?
        let interactions: [LeadInteractionRow]
        let sendDates: [Date]
        let replied: Bool
    }

    private enum Stage: Int { case scraped, researched, personalized, campaigned }

    private static func spec(_ i: Int, now: Date) -> Spec {
        let id = String(format: "demo-%04d", i)
        // Spread the 160 prefix×suffix pairs so neighbouring rows don't share a word.
        let pair = (i * 37) % (prefixes.count * suffixes.count)
        let prefix = prefixes[pair % prefixes.count]
        let company = "\(prefix) \(suffixes[pair / prefixes.count])"
        let domain = prefix.lowercased().filter(\.isLetter) + "solar.example"
        let place = places[(i * 5) % places.count]
        let source = place.2 != nil ? "sales-nav" : sources[i % sources.count]

        // Partial data, the way a real book is partial.
        let first: String? = i % 7 == 3 ? nil : firstNames[(i * 5) % firstNames.count]
        let last: String? = first == nil || i % 13 == 5 ? nil : lastNames[(i * 3) % lastNames.count]
        let email: String? = i % 11 == 4 ? nil
            : (first.map { "\($0.lowercased())@\(domain)" } ?? "info@\(domain)")
        let phone: String? = i % 6 == 2 ? nil : String(format: "(%@) 555-01%02d", place.3, i % 100)
        let website: String? = i % 9 == 7 ? nil : "https://www.\(domain)/"
        let industry = industries[(i * 3) % industries.count]

        // Funnel: ~30% scraped, ~25% researched, ~20% personalized, ~25% campaigned.
        // Newer leads sit earlier in the funnel, as they do in a live pipeline.
        let created = createdDate(i, now: now)
        let ageDays = now.timeIntervalSince(created) / 86_400
        let bucket = (i * 41) % 100
        var stage: Stage = bucket < 30 ? .scraped : bucket < 55 ? .researched
            : bucket < 75 ? .personalized : .campaigned
        if stage == .campaigned && ageDays < 4 { stage = .personalized }
        let deep = stage.rawValue >= Stage.personalized.rawValue && i % 9 == 0
        let replied = stage == .campaigned && i % 10 == 1

        // Sends: up to three sequence steps, three days apart, never in the future.
        var sendDates: [Date] = []
        if stage == .campaigned {
            for step in 0..<3 {
                let at = created.addingTimeInterval(Double(2 + step * 3) * 86_400
                                                    + Double((i * 97) % 600) * 60)
                if at < now { sendDates.append(at) }
            }
            if replied { sendDates = Array(sendDates.prefix(i % 2 == 1 ? 1 : 2)) }
        }

        let outreach: String
        switch (stage, replied, sendDates.count) {
        case (.campaigned, true, _): outreach = "replied"
        case (.campaigned, false, 3): outreach = "sequence_done"
        case (.campaigned, false, _): outreach = "in_sequence"
        default: outreach = "untouched"
        }

        let row = LeadRow(
            id: id, companyName: company, firstName: first, industry: industry,
            leadSource: source, city: place.0, state: place.1, createdAt: iso(created),
            outreach: outreach, deepening: deep ? "in_progress" : "none",
            personalized: stage.rawValue >= Stage.personalized.rawValue,
            hasResearch: stage != .scraped, statusRowMissing: false,
            location: place.2, country: place.0 == nil && place.2 == nil ? "US" : nil,
            lastName: last, email: email)

        let cityName = place.0 ?? place.2?.replacingOccurrences(of: "Greater ", with: "")
            .replacingOccurrences(of: " Area", with: "")
        let project = projects[(i * 5) % projects.count]
        let founded = 2008 + (i * 7) % 16
        let description: String? = i % 8 == 6 ? nil
            : "\(company) designs and installs residential and commercial solar"
            + (cityName.map { " across the \($0) area" } ?? "")
            + ", with a growing focus on \(project)."

        let detail = LeadDetailRow(
            id: id, email: email, firstName: first, lastName: last, fullName: nil,
            companyName: company, jobTitle: first == nil ? nil : titles[i % titles.count],
            companyDescription: description, location: place.2, city: place.0,
            state: place.1, phone: phone, website: website, industry: industry)

        var enrichment: LeadEnrichmentRow? = nil
        if stage != .scraped {
            var research: [String: JSONValue] = [
                "company_summary": .string(description ?? "\(company) is a solar installer."),
                "founded_year": .string(String(founded)),
                "services": .array(["Residential solar", "Battery storage",
                                    project.prefix(1).uppercased() + project.dropFirst()]
                    .map { .string($0) }),
                "confidence": .number(Double(2 + i % 3)),
            ]
            if i % 4 == 0 { research["awards_or_news"] = .string("None found.") }
            let personalized = stage.rawValue >= Stage.personalized.rawValue
            let n = 12 + (i * 11) % 140
            let shortName = prefix
            let (detailFormat, openerFormat) = details[i % details.count]
            enrichment = LeadEnrichmentRow(
                casualizedFirstName: personalized ? first : nil,
                casualizedCompanyName: personalized ? shortName : nil,
                casualizedCityName: personalized ? cityName : nil,
                personalizationProject: personalized ? project : nil,
                personalizationDetail: personalized ? String(format: detailFormat, n) : nil,
                personalizedOpener: personalized
                    ? String(format: openerFormat, shortName, project, n) : nil,
                personalizedOffer: personalized ? offers[i % offers.count] : nil,
                research: .object(research),
                casualizedShape: personalized ? "object" : nil)
        }

        let interactions = pipelineEvents(i: i, stage: stage, created: created, source: source,
                                          hasEmail: email != nil, now: now)
            + timeline(i: i, company: prefix, first: first, opener: enrichment?.personalizedOpener,
                       offer: enrichment?.personalizedOffer, sendDates: sendDates,
                       replied: replied, now: now)
        return Spec(row: row, detail: detail, enrichment: enrichment,
                    interactions: interactions, sendDates: sendDates, replied: replied)
    }

    /// Outbound sequence steps, then (for repliers) the inbound reply tagged
    /// with sentiment and intent, and for the warmest a booked call.
    /// What the backend did to this lead before any email: sourced, researched,
    /// personalized, verified. Every dossier has at least the first event, so no
    /// click in the demo lands on an empty timeline.
    private static func pipelineEvents(i: Int, stage: Stage, created: Date, source: String,
                                       hasEmail: Bool, now: Date) -> [LeadInteractionRow] {
        let sourceLabel = ["gmaps-leads": "Google Maps scrape", "sales-nav": "LinkedIn Sales Navigator",
                           "jobsignal": "a job-posting signal",
                           "gmaps-email-discovered": "Google Maps + email discovery"][source] ?? source
        var steps: [(String, String)] = [("Lead sourced", "Added from \(sourceLabel).")]
        if stage.rawValue >= Stage.researched.rawValue {
            steps.append(("Research dossier written",
                          "Company summary, services and founding year captured."))
        }
        if stage.rawValue >= Stage.personalized.rawValue {
            steps.append(("Copy personalized", "Opener and offer generated from the research."))
            if hasEmail { steps.append(("Email verified", "Deliverability check passed.")) }
        }
        return steps.enumerated().compactMap { n, step in
            let at = created.addingTimeInterval(Double(n) * 0.6 * 86_400)
            guard at <= now else { return nil }
            return LeadInteractionRow(
                id: "demo-evt-\(i)-\(n)", interactionType: "pipeline", direction: "pipeline",
                subject: step.0, summary: step.1, transcript: nil, metadata: nil,
                source: "hermes", interactionAt: iso(at))
        }
    }

    private static func timeline(i: Int, company: String, first: String?, opener: String?,
                                 offer: String?, sendDates: [Date], replied: Bool,
                                 now: Date) -> [LeadInteractionRow] {
        let subjects = ["quick question about \(company)'s quotes",
                        "re: quick question about \(company)'s quotes",
                        "closing the loop"]
        let greeting = "Hi \(first ?? "there"),"
        let summaries = [
            [greeting, opener, offer, "Worth a 15-minute call?"].compactMap { $0 }
                .joined(separator: " "),
            "\(greeting) following up on my note below. Happy to send a 2-minute "
                + "walkthrough of how the quote follow-up works.",
            "\(greeting) I'll stop here. If quote follow-up ever becomes a bottleneck, "
                + "just reply and we'll pick it up.",
        ]
        var rows: [LeadInteractionRow] = sendDates.enumerated().map { step, at in
            LeadInteractionRow(
                id: "demo-int-\(i)-\(step)", interactionType: "email", direction: "outbound",
                subject: subjects[step], summary: summaries[step], transcript: nil,
                metadata: .object(["step_number": .number(Double(step + 1)),
                                   "variant_index": .number(Double(i % 3))]),
                source: "ce-outbound", interactionAt: iso(at))
        }
        guard replied, let lastSend = sendDates.last else { return rows }

        let replies: [(String, String, String)] = [
            ("positive", "book_call",
             "This is timely. We lose a lot of quotes after the site visit. Can you do Thursday?"),
            ("interested", "more_info",
             "Interesting. How does the follow-up work with our CRM? Send over some details."),
            ("question", "pricing",
             "What does something like this cost for a crew our size?"),
            ("neutral", "later", "Busy season right now. Reach back out in January."),
        ]
        // Four repliers in the book, four distinct sentiments.
        let reply = replies[(i / 10) % replies.count]
        let replyAt = min(now.addingTimeInterval(-3_600),
                          lastSend.addingTimeInterval(Double(2 + i % 5) * 3_600))
        rows.append(LeadInteractionRow(
            id: "demo-int-\(i)-reply", interactionType: "email", direction: "inbound",
            subject: "Re: \(subjects[0])",
            summary: reply.2, transcript: nil,
            metadata: .object(["sentiment": .string(reply.0), "intent": .string(reply.1)]),
            source: "ce-autoreply", interactionAt: iso(replyAt)))
        if reply.1 == "book_call" {
            let callAt = replyAt.addingTimeInterval(2 * 86_400)
            rows.append(LeadInteractionRow(
                id: "demo-int-\(i)-call", interactionType: "meeting", direction: "booked",
                subject: "Discovery call\(first.map { " with \($0)" } ?? "")",
                summary: "Booked via Cal.com from the reply. Pre-call briefing generated.",
                transcript: nil, metadata: nil, source: "cal.com",
                interactionAt: iso(callAt)))
        }
        return rows
    }

    /// Newer leads are denser, so the trend chart shows a growing pipeline
    /// rather than a flat line. Spans ~75 days back from `now`.
    private static func createdDate(_ i: Int, now: Date) -> Date {
        let frac = Double((i * 61) % count) / Double(count)
        let days = 75 * pow(frac, 1.5)
        let minutes = Double((i * 131) % 600)
        return now.addingTimeInterval(-(days * 86_400 + minutes * 60))
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
