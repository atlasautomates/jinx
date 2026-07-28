import Foundation
import SwiftUI

/// Synthetic dossier for the `--screenshot profile` renders. No PII, no
/// network, no Supabase, no Keychain — same contract as ABLeadsFixture.
enum LeadProfileFixture {
    static let ref = LeadRef(id: "fixture-lead",
                             companyName: "Northwind Solar",
                             email: "team@northwind.example")

    static var inputs: ProfileInputs {
        ProfileInputs(
            lead: LeadDetailRow(
                id: ref.id,
                email: "team@northwind.example",
                firstName: "Dana", lastName: "Reyes", fullName: nil,
                companyName: "Northwind Solar",
                jobTitle: "Owner",
                companyDescription: "Family-owned solar and storage installer serving "
                    + "the Treasure Coast, plus remote design support for DIY builds.",
                location: nil, city: "Stuart", state: "Florida",
                phone: "(555) 320-2842",
                website: "https://www.northwind.example/",
                industry: "Solar energy system service"),
            enrichment: LeadEnrichmentRow(
                casualizedFirstName: "Dana",
                casualizedCompanyName: "Northwind",
                casualizedCityName: "Stuart",
                personalizationProject: "off-grid RV installs",
                personalizationDetail: "12 installs listed in the 2026 gallery",
                personalizedOpener: "Saw Northwind's off-grid RV gallery — twelve builds "
                    + "posted this year is a lot of quoting for a three-person shop.",
                personalizedOffer: "We reactivate your old quote list with a 5-email "
                    + "sequence, so the ones who went quiet get a reason to come back.",
                enrichmentSource: "local-web-research",
                enrichmentStatus: "partial",
                leadTier: "2",
                webResearchJson: .object([
                    "company_summary": .string("Family-owned solar and energy storage "
                        + "company specializing in RV, van, and off-grid installs."),
                    "confidence": .number(3),
                    "awards_or_news": .string("None found."),
                    "founded_year": .string("2018"),
                ])),
            interactions: [],
            sentiment: nil,
            intent: nil,
            partial: false,
            interactionsFailed: false,
            interactionsTruncated: false)
    }

    /// The states `--screenshot profile-copy` forces. Declared HERE, not inline
    /// in the registry, so `--selftest` can assert these labels name real facts:
    /// a typo would render the copy view identically to the plain one and
    /// silently stop proving the affordance exists.
    static let copyDemo = CopyDemo(hoverLabel: "Industry", copiedLabel: "Email")

    /// Scratch pins directory for the preview. Per-run unique: with `TMPDIR`
    /// stripped (a launchd or CI context) `temporaryDirectory` falls back to the
    /// world-writable `/tmp`, where a planted `pinned-leads.json` would decode
    /// into the rendered PNG. A UUID component makes that unaddressable.
    /// Held as a `static let` so the model is built once, not per body
    /// evaluation — its init reads from disk.
    @MainActor
    private static let previewPins = PinsModel(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CECDashboard-preview-\(UUID().uuidString)",
                                    isDirectory: true))

    /// A fixed-width render of the sheet on the harness canvas. The pins model
    /// points at a scratch directory so a preview can never read or write the
    /// real pin file.
    @MainActor
    static func view(demo: CopyDemo = CopyDemo()) -> some View {
        LeadProfileView(ref: ref, previewInputs: inputs, copyDemo: demo,
                        staticRender: true)
            .frame(width: 760, height: 940)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bgRoot)
            .environment(previewPins)
            .environment(\.isStaticRender, true)
    }
}
