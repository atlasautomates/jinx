import Foundation

/// Headless lead query for automation and the Aris voice gate (run with `--query <metric>`).
/// Prints ONE spoken-friendly line to stdout and exits 0; errors go to stderr, exit 1.
///
///   CECDashboard --query count
///   CECDashboard --query by-industry
///
/// Why a CLI and not `shortcuts run`: auto-provided App Shortcuts (the Siri surface in
/// `Intents.swift`) don't appear in `shortcuts list` and aren't runnable by name from the
/// CLI — so a subprocess gate (Aris) can't reach them that way. This mode exposes the same
/// data the App Intents speak, reusing the dashboard read path (LeadsRepository + the
/// Keychain reader JWT), as a plain subprocess Aris can call and read back. The metric
/// vocabulary is a CROSS-PROCESS CONTRACT with the Aris gate's `_LEAD_METRICS` allow-list
/// (builds/aris-voice-gate/tools/handlers.py) — pinned by
/// `.claude/tests/test_cec_view_contract.py`, because "kept in step by hand" broke once.
enum LeadQuery {
    static func run() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--query"), i + 1 < args.count else {
            fail("usage: --query <count|by-source|by-industry>")
        }
        let metric = args[i + 1].lowercased()
        // Validate BEFORE touching the Keychain: an unknown metric needs no
        // credential, and a stale allow-list entry upstream was burning a
        // Keychain access (which can prompt) for a request rejected
        // unconditionally (contention lens).
        let known: Set<String> = ["count", "total", "total-leads",
                                  "by-source", "source", "sources",
                                  "by-industry", "industry", "industries"]
        guard known.contains(metric) else {
            fail(QueryError.unknownMetric(metric).errorDescription ?? "unknown metric")
        }

        let semaphore = DispatchSemaphore(value: 0)
        // Locked box, not captured vars: mutable locals captured by a Task are a
        // Swift 6 sending error, and the semaphore is the happens-before barrier
        // (the SupabaseCheck.Result discipline).
        final class Result: @unchecked Sendable {
            var output: String?
            var errorMessage = "unknown error"
        }
        let result = Result()

        // Mirrors SupabaseCheck: init() blocks the main thread on the wait below, so this
        // Task body must stay off the main actor (pure networking + Keychain) to avoid a
        // continuation deadlock. Bounded so the query can never hang indefinitely.
        Task {
            do {
                let repo = LeadsRepository(client: try SupabaseClient.make())
                result.output = try await answer(for: metric, repo: repo)
            } catch {
                result.errorMessage = error.localizedDescription
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            fail("timed out after 20s")
        }
        if let output = result.output {
            print(output)
            exit(0)
        }
        fail(result.errorMessage)
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
        // by-tier retired with lead_enrichment.lead_tier (7.2) — runtime
        // score_lead is the only tier source now, and it never landed in a column.
        default:
            throw QueryError.unknownMetric(metric)
        }
    }

    enum QueryError: Error, LocalizedError {
        case unknownMetric(String)
        var errorDescription: String? {
            switch self {
            case .unknownMetric(let m):
                return "unknown metric '\(m)' (use count|by-source|by-industry)"
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("QUERY FAIL — \(message)\n".utf8))
        exit(1)
    }
}
