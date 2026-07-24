import Foundation

// FROZEN A/B FIXTURE — mirrors AB-ARM/ab-fixture.json EXACTLY. Synthetic, no
// PII, no network, no Supabase. Both arms render this identical data. Embedded
// as an in-memory Swift value so the Leads tab renders deterministically.

struct ABLeadsData {
    struct Totals { let scraped: Int; let emailed: Int; let replies: Int }
    struct Series { let weeks: [String]; let values: [Int] }
    struct Breakdown: Identifiable { let label: String; let count: Int; var id: String { label } }
    struct Lead: Identifiable {
        let company: String; let industry: String; let location: String
        let source: String; let status: String; let added: String
        var id: String { company }
    }

    let totals: Totals
    let emailedOfScrapedPct: Double
    let repliesOfEmailedPct: Double
    let leadsAddedWeekly: Series
    let leadsMessagedWeekly: Series
    let bySource: [Breakdown]
    let byIndustry: [Breakdown]
    let byStatus: [Breakdown]
    let recentLeads: [Lead]

    static let ab = ABLeadsData(
        totals: .init(scraped: 1240, emailed: 861, replies: 74),
        emailedOfScrapedPct: 69.4,
        repliesOfEmailedPct: 8.6,
        leadsAddedWeekly: .init(
            weeks: ["May 4","May 11","May 18","May 25","Jun 1","Jun 8","Jun 15","Jun 22","Jun 29","Jul 6","Jul 13","Jul 20"],
            values: [34,41,52,48,61,75,58,66,82,91,77,88]),
        leadsMessagedWeekly: .init(
            weeks: ["May 4","May 11","May 18","May 25","Jun 1","Jun 8","Jun 15","Jun 22","Jun 29","Jul 6","Jul 13","Jul 20"],
            values: [20,28,35,33,47,51,44,50,63,70,58,67]),
        bySource: [
            .init(label: "Sales Navigator", count: 512),
            .init(label: "Google Maps", count: 388),
            .init(label: "Apollo", count: 204),
            .init(label: "Job Signals", count: 136),
        ],
        byIndustry: [
            .init(label: "Assisted Living", count: 296),
            .init(label: "Residential Solar", count: 248),
            .init(label: "Biotech", count: 183),
            .init(label: "EV Dealers", count: 187),
            .init(label: "Credit Unions", count: 174),
            .init(label: "Web Agencies", count: 152),
        ],
        byStatus: [
            .init(label: "Scraped", count: 379),
            .init(label: "Enriched", count: 240),
            .init(label: "Personalized", count: 160),
            .init(label: "Emailed", count: 285),
            .init(label: "Replied", count: 74),
            .init(label: "Bounced", count: 42),
            .init(label: "Do not contact", count: 60),
        ],
        recentLeads: [
            .init(company: "Ostrowen Senior Care", industry: "Assisted Living", location: "Tampa, FL", source: "Google Maps", status: "Emailed", added: "2026-07-20"),
            .init(company: "Sorrelwick Solar Co", industry: "Residential Solar", location: "Phoenix, AZ", source: "Sales Navigator", status: "Replied", added: "2026-07-20"),
            .init(company: "Quorrel Biolabs", industry: "Biotech", location: "Basel, CH", source: "Apollo", status: "Enriched", added: "2026-07-19"),
            .init(company: "Crestline EV Motors", industry: "EV Dealers", location: "Orlando, FL", source: "Sales Navigator", status: "Personalized", added: "2026-07-19"),
            .init(company: "Kestrelbrook Credit Union", industry: "Credit Unions", location: "Sacramento, CA", source: "Apollo", status: "Emailed", added: "2026-07-18"),
            .init(company: "Brightmoor Web Studio", industry: "Web Agencies", location: "Austin, TX", source: "Job Signals", status: "Scraped", added: "2026-07-18"),
            .init(company: "Fernhollow Assisted Living", industry: "Assisted Living", location: "Naples, FL", source: "Google Maps", status: "Emailed", added: "2026-07-17"),
            .init(company: "Zephyrine Home Energy", industry: "Residential Solar", location: "Tucson, AZ", source: "Google Maps", status: "Emailed", added: "2026-07-17"),
            .init(company: "Halvorine Therapeutics", industry: "Biotech", location: "Munich, DE", source: "Apollo", status: "Enriched", added: "2026-07-16"),
            .init(company: "Wrenfield EV Gallery", industry: "EV Dealers", location: "San Jose, CA", source: "Sales Navigator", status: "Emailed", added: "2026-07-16"),
            .init(company: "Thornmere Federal CU", industry: "Credit Unions", location: "Fresno, CA", source: "Apollo", status: "Personalized", added: "2026-07-15"),
            .init(company: "Larkspire & Vine Design", industry: "Web Agencies", location: "Dallas, TX", source: "Job Signals", status: "Emailed", added: "2026-07-15"),
            .init(company: "Hazelquist Care", industry: "Assisted Living", location: "Sarasota, FL", source: "Google Maps", status: "Replied", added: "2026-07-14"),
            .init(company: "Glimmerhaw Solar Partners", industry: "Residential Solar", location: "Mesa, AZ", source: "Sales Navigator", status: "Emailed", added: "2026-07-14"),
            .init(company: "Cobalt Bio Systems", industry: "Biotech", location: "Copenhagen, DK", source: "Apollo", status: "Scraped", added: "2026-07-13"),
            .init(company: "Corvane Electric Autos", industry: "EV Dealers", location: "Las Vegas, NV", source: "Sales Navigator", status: "Emailed", added: "2026-07-13"),
            .init(company: "Brindleback CU", industry: "Credit Unions", location: "San Diego, CA", source: "Apollo", status: "Emailed", added: "2026-07-12"),
            .init(company: "Inkwhistle Studios", industry: "Web Agencies", location: "Houston, TX", source: "Job Signals", status: "Enriched", added: "2026-07-12"),
            .init(company: "Bramblewick Living", industry: "Assisted Living", location: "Clearwater, FL", source: "Google Maps", status: "Emailed", added: "2026-07-11"),
            .init(company: "Cobblequartz Solar", industry: "Residential Solar", location: "Scottsdale, AZ", source: "Google Maps", status: "Bounced", added: "2026-07-11"),
            .init(company: "Tidemarrow Biometrics", industry: "Biotech", location: "Amsterdam, NL", source: "Apollo", status: "Emailed", added: "2026-07-10"),
            .init(company: "Velocity EV Outlet", industry: "EV Dealers", location: "Reno, NV", source: "Sales Navigator", status: "Scraped", added: "2026-07-10"),
            .init(company: "Thistlecombe CU", industry: "Credit Unions", location: "Bakersfield, CA", source: "Apollo", status: "Emailed", added: "2026-07-09"),
            .init(company: "Glintmoor Web Co", industry: "Web Agencies", location: "San Antonio, TX", source: "Job Signals", status: "Personalized", added: "2026-07-09"),
        ]
    )
}

// Status -> role color mapping (two-accent discipline; decision-log #5).
enum ABStatusRole {
    case reward      // Replied -> pink
    case active      // Emailed -> teal
    case warn        // Bounced / Do not contact -> warm neutral
    case neutral     // Scraped / Enriched / Personalized

    init(_ status: String) {
        switch status.lowercased() {
        case "replied":                       self = .reward
        case "emailed":                       self = .active
        case "bounced", "do not contact":     self = .warn
        default:                              self = .neutral
        }
    }
}
