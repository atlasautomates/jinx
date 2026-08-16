import AppIntents
import Foundation

/// App Intents — the Siri / Shortcuts surface (and, via `shortcuts run`, the Aris
/// voice-gate surface). The headless query intents answer by voice WITHOUT opening
/// the window, reusing the same read path as the dashboard (`LeadsRepository` +
/// the Keychain reader JWT). `OpenDashboardIntent` foregrounds the UI.
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

/// A real deadline, not a decorative one. The previous task-group shape
/// picked its VALUE at the deadline but could not RETURN until the orphaned
/// `SecItemCopyMatching` finished — `withTaskGroup` awaits all children, and
/// cancellation cannot interrupt a synchronous Security call — so the exact
/// scenario the deadline exists for (an invisible auth prompt in a background
/// launch) hung the intent anyway (contention lens, proven with a compiled
/// repro). Now the blocking read runs on a GCD thread we are WILLING TO LEAK
/// while a continuation is resumed by whichever side finishes first; the
/// attributes-only `Keychain.exists` preflight short-circuits the common
/// not-configured case without ever materializing the secret or prompting.
private func boundedClientBuild(seconds: Double) async -> SupabaseClient? {
    guard Keychain.exists(service: SupabaseConfig.keychainService,
                          account: SupabaseConfig.keychainAccount),
          Keychain.exists(service: SupabaseConfig.keychainService,
                          account: SupabaseConfig.anonKeychainAccount) else { return nil }
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }
            if fired { return false }; fired = true; return true }
    }
    let once = Once()
    return await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let client = try? SupabaseClient.make()   // may block on a prompt
            if once.claim() { cont.resume(returning: client) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if once.claim() { cont.resume(returning: nil) }
        }
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

// `tier` retired with lead_enrichment.lead_tier (7.2 remap): the column is gone
// and runtime score_lead is the only tier source. Removing an AppEnum case is
// safe — a stale Shortcut carrying "tier" fails parameter resolution rather
// than fetching from a dead table.
enum LeadBreakdownDimension: String, AppEnum {
    case source, industry

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lead Breakdown")
    static let caseDisplayRepresentations: [LeadBreakdownDimension: DisplayRepresentation] = [
        .source: "Source",
        .industry: "Industry",
    ]

    /// Spoken nouns — keeps voice output grammatical (avoids "industrys") instead of
    /// naively appending "s" to `rawValue`.
    var spokenSingular: String {
        switch self {
        case .source: return "source"
        case .industry: return "industry"
        }
    }
    var spokenPlural: String {
        switch self {
        case .source: return "sources"
        case .industry: return "industries"
        }
    }
}

struct LeadBreakdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Lead Breakdown"
    static let description = IntentDescription("The top groups of leads by source or industry.")

    @Parameter(title: "Group by")
    var dimension: LeadBreakdownDimension

    static var parameterSummary: some ParameterSummary {
        Summary("Lead breakdown by \(\.$dimension)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repo = try await makeRepository()
        let result: (counts: [String: Int], sampled: Bool)
        do { result = try await Self.counts(for: dimension, repo: repo) }
        catch { throw CECDashboardIntentError.fetchFailed }

        // Shared with the --query CLI via LeadAnswers so Siri and Aris never drift.
        let spoken = LeadAnswers.breakdown(result.counts,
                                           singular: dimension.spokenSingular,
                                           plural: dimension.spokenPlural,
                                           sampled: result.sampled)
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }

    private static func counts(
        for dim: LeadBreakdownDimension, repo: LeadsRepository
    ) async throws -> (counts: [String: Int], sampled: Bool) {
        switch dim {
        case .source:
            return try await LeadAnswers.breakdownCounts(repo: repo) { $0.leadSource }
        case .industry:
            return try await LeadAnswers.breakdownCounts(repo: repo) { $0.industry }
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
