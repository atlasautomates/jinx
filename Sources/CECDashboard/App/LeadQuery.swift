import Foundation

/// Headless lead query for automation and the Aris voice gate (run with `--query <metric>`).
/// Prints ONE spoken-friendly line to stdout and exits 0; errors go to stderr, exit 1.
///
///   CECDashboard --query count
///   CECDashboard --query by-tier
///
/// Why a CLI and not `shortcuts run`: auto-provided App Shortcuts (the Siri surface in
/// `Intents.swift`) don't appear in `shortcuts list` and aren't runnable by name from the
/// CLI — so a subprocess gate (Aris) can't reach them that way. This mode exposes the same
/// data the App Intents speak, reusing the dashboard read path (LeadsRepository + Keychain
/// anon key), as a plain subprocess Aris can call and read back. Phrasing intentionally
/// mirrors `Intents.swift` (presentation only — not a data contract; kept in step by hand).
enum LeadQuery {
    static func run() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--query"), i + 1 < args.count else {
            fail("usage: --query <count|by-source|by-industry|by-tier>")
        }
        let metric = args[i + 1].lowercased()

        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        var errorMessage = "unknown error"

        // Mirrors SupabaseCheck: init() blocks the main thread on the wait below, so this
        // Task body must stay off the main actor (pure networking + Keychain) to avoid a
        // continuation deadlock. Bounded so the query can never hang indefinitely.
        Task {
            do {
                let repo = LeadsRepository(client: try SupabaseClient.make())
                output = try await answer(for: metric, repo: repo)
            } catch {
                errorMessage = error.localizedDescription
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            fail("timed out after 20s")
        }
        if let output {
            print(output)
            exit(0)
        }
        fail(errorMessage)
    }

    private static func answer(for metric: String, repo: LeadsRepository) async throws -> String {
        // Phrasing/aggregation live in LeadAnswers, shared with the App Intents (Siri),
        // so the two surfaces speak identical data.
        switch metric {
        case "count", "total", "total-leads":
            return LeadAnswers.count(try await repo.totalCount())
        case "by-source", "source", "sources":
            let r = try await LeadAnswers.breakdownCounts(repo: repo) { $0.leadSource }
            return LeadAnswers.breakdown(r.counts, singular: "source", plural: "sources", sampled: r.sampled)
        case "by-industry", "industry", "industries":
            let r = try await LeadAnswers.breakdownCounts(repo: repo) { $0.industry }
            return LeadAnswers.breakdown(r.counts, singular: "industry", plural: "industries", sampled: r.sampled)
        case "by-tier", "tier", "tiers":
            return LeadAnswers.breakdown(await repo.tierCounts(), singular: "tier", plural: "tiers")
        default:
            throw QueryError.unknownMetric(metric)
        }
    }

    enum QueryError: Error, LocalizedError {
        case unknownMetric(String)
        var errorDescription: String? {
            switch self {
            case .unknownMetric(let m):
                return "unknown metric '\(m)' (use count|by-source|by-industry|by-tier)"
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QUERY FAIL — \(message)\n".utf8))
        exit(1)
    }
}
