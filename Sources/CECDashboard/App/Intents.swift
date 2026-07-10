import AppIntents
import Foundation

/// App Intents — the Siri / Shortcuts surface (and, via `shortcuts run`, the Aris
/// voice-gate surface). The headless query intents answer by voice WITHOUT opening
/// the window, reusing the same read path as the dashboard (`LeadsRepository` +
/// Keychain anon key). `OpenDashboardIntent` foregrounds the UI.
///
/// Auto-discovered by the App Intents framework — no wiring in the @main App needed.
/// Requires the app to have been launched once (to grant the Keychain "Always Allow").

enum CECDashboardIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case fetchFailed
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            return "CEC Dashboard isn't set up yet — open the app once to connect it."
        case .fetchFailed:
            return "Couldn't reach the leads database."
        }
    }
}

/// Build the repository for a HEADLESS intent. The Keychain read inside
/// `SupabaseClient.make()` is synchronous and can block on an "allow access" prompt
/// if the app isn't yet trusted for the item — e.g. the user issued a voice command
/// (or the Aris gate ran `shortcuts run`) before ever opening the app once to grant
/// "Always Allow". In a background launch that prompt may be invisible, so we race
/// the build against a short deadline and map a stall (or any failure) to
/// `.notConfigured` — Siri gets a clean, honest answer instead of a hang.
private func makeRepository() async throws -> LeadsRepository {
    guard let client = await boundedClientBuild(seconds: 3) else {
        throw CECDashboardIntentError.notConfigured
    }
    return LeadsRepository(client: client)
}

private func boundedClientBuild(seconds: Double) async -> SupabaseClient? {
    await withTaskGroup(of: SupabaseClient?.self) { group in
        group.addTask { try? SupabaseClient.make() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil   // deadline won the race → treat as not-configured
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - Lead count (headless, spoken)

struct LeadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Lead Count"
    static let description = IntentDescription("How many leads are in the database.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let repo = try await makeRepository()
        let count: Int
        do { count = try await repo.totalCount() } catch { throw CECDashboardIntentError.fetchFailed }
        return .result(value: count, dialog: IntentDialog(stringLiteral: LeadAnswers.count(count)))
    }
}

// MARK: - Lead breakdown by dimension (headless, spoken)

enum LeadBreakdownDimension: String, AppEnum {
    case source, industry, tier

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lead Breakdown")
    static let caseDisplayRepresentations: [LeadBreakdownDimension: DisplayRepresentation] = [
        .source: "Source",
        .industry: "Industry",
        .tier: "Tier",
    ]

    /// Spoken nouns — keeps voice output grammatical (avoids "industrys") instead of
    /// naively appending "s" to `rawValue`.
    var spokenSingular: String {
        switch self {
        case .source: return "source"
        case .industry: return "industry"
        case .tier: return "tier"
        }
    }
    var spokenPlural: String {
        switch self {
        case .source: return "sources"
        case .industry: return "industries"
        case .tier: return "tiers"
        }
    }
}

struct LeadBreakdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Lead Breakdown"
    static let description = IntentDescription("The top groups of leads by source, industry, or tier.")

    @Parameter(title: "Group by")
    var dimension: LeadBreakdownDimension

    static var parameterSummary: some ParameterSummary {
        Summary("Lead breakdown by \(\.$dimension)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repo = try await makeRepository()
        let result: (counts: [String: Int], sampled: Bool, incomplete: Bool)
        do { result = try await Self.counts(for: dimension, repo: repo) }
        catch { throw CECDashboardIntentError.fetchFailed }

        // Shared with the --query CLI via LeadAnswers so Siri and Aris never drift.
        let spoken = LeadAnswers.breakdown(result.counts,
                                           singular: dimension.spokenSingular,
                                           plural: dimension.spokenPlural,
                                           sampled: result.sampled,
                                           incomplete: result.incomplete)
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }

    private static func counts(
        for dim: LeadBreakdownDimension, repo: LeadsRepository
    ) async throws -> (counts: [String: Int], sampled: Bool, incomplete: Bool) {
        switch dim {
        case .tier:
            // A degraded/floored tier read must not be spoken as exact.
            let r = await repo.tierCountsResult()
            return (r.counts, false, !r.ok)
        case .source:
            let r = try await LeadAnswers.breakdownCounts(repo: repo) { $0.leadSource }
            return (r.counts, r.sampled, false)
        case .industry:
            let r = try await LeadAnswers.breakdownCounts(repo: repo) { $0.industry }
            return (r.counts, r.sampled, false)
        }
    }
}

// MARK: - Open the dashboard (interactive)

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open CEC Dashboard"
    static let description = IntentDescription("Opens the CEC Dashboard window.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - Siri / Spotlight phrases (every phrase must include the app name)

struct CECDashboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LeadCountIntent(),
            phrases: ["How many leads in \(.applicationName)",
                      "\(.applicationName) lead count"],
            shortTitle: "Lead Count",
            systemImageName: "number"
        )
        AppShortcut(
            intent: LeadBreakdownIntent(),
            phrases: ["Lead breakdown in \(.applicationName)",
                      "Show \(.applicationName) breakdown"],
            shortTitle: "Lead Breakdown",
            systemImageName: "chart.pie"
        )
        AppShortcut(
            intent: OpenDashboardIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Dashboard",
            systemImageName: "rectangle.3.group"
        )
    }
}
