import Foundation

/// Headless Supabase connectivity check (run with `--check-supabase`).
/// Verifies the Keychain key + a read against `leads`. Run on a networked Mac;
/// it will fail in a sandboxed/offline context (expected).
enum SupabaseCheck {
    /// Result crosses the Task→main-thread boundary via the same
    /// @unchecked Sendable box discipline SelfTest uses; the semaphore is the
    /// happens-before barrier (swift-semantics review — documents intent and
    /// keeps Swift 6 honest about why this is safe).
    private final class Result: @unchecked Sendable {
        var ok = false
        var message = "unknown"
    }

    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Result()

        Task {
            do {
                let client = try SupabaseClient.make()
                let repo = LeadsRepository(client: client)
                let pipeRepo = PipelineRepository(client: client)
                // Independent probes fan out CONCURRENTLY: 6 sequential reads
                // could exceed the 20s wall on a slow-but-healthy network and
                // read as a broken install (reliability + platform reviews).
                // NOTE: leadsProbe exercises the REAL essential select (incl.
                // enrichment_stage) — ping()'s id-only read would stay green
                // while a missing column 400s the whole Leads tab.
                async let leadsProbeTask = repo.recentLeads(limit: 1)
                async let tiersTask = repo.tierCounts()
                async let sentimentTask = repo.sentimentCounts()
                async let runsTask = pipeRepo.recentRuns()
                async let eventsTask: [PipelineLeadEventRow]? = try? pipeRepo.leadEvents(
                    leadId: "00000000-0000-0000-0000-000000000000") // shape/RLS probe; expect []

                let leadsProbe = try await leadsProbeTask           // essential
                let tiers = await tiersTask
                let sentiment = await sentimentTask
                let runs = (try? await runsTask) ?? []
                let events = await eventsTask
                // Stage read depends on run ids — the one sequential follow-up.
                let (stageRows, stagesOK) = await pipeRepo.stageRuns(
                    runIds: runs.prefix(3).map(\.runId))
                result.ok = true
                let tierStr = tiers.isEmpty ? "by-tier: EMPTY (no rows / no RLS policy)"
                    : "by-tier: \(tiers.values.reduce(0, +)) rows, \(tiers.count) tiers \(tiers.keys.sorted())"
                let sentStr = sentiment.isEmpty ? "sentiment: EMPTY (no rows / no RLS policy)"
                    : "sentiment: \(sentiment.values.reduce(0, +)) rows \(sentiment.keys.sorted())"
                let pipeStr = "pipeline: \(runs.count) run(s), \(stageRows.count) stage row(s)"
                    + (stagesOK ? "" : " (stage read FAILED)")
                    + (events == nil ? ", lead_events read FAILED (no RLS policy?)" : ", lead_events readable")
                    + (runs.isEmpty ? " — EMPTY (no runs / no RLS policy on pipeline_runs)" : "")
                result.message = "reached \(client.baseURL.host ?? "supabase"), "
                    + "\(leadsProbe.count) lead(s) sampled (full select incl. enrichment_stage)"
                    + "\n  \(tierStr)\n  \(sentStr)\n  \(pipeStr)"
            } catch {
                result.message = error.localizedDescription
            }
            semaphore.signal()
        }
        // init() blocks the main thread on this wait, so the Task body above must stay
        // off the main actor (pure networking + Keychain) or its continuation would
        // deadlock against this wait. Bounded so the probe can never hang indefinitely.
        // PIN: LeadsRepository/PipelineRepository/SupabaseClient must stay
        // non-@MainActor — annotating any of them would move the Task body onto
        // the main actor and deadlock this wait (degrading to a spurious
        // 20s-timeout FAIL). Enforced by review, not the compiler.
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            FileHandle.standardError.write(Data("SUPABASE CHECK FAIL — timed out after 20s\n".utf8))
            exit(1)
        }

        if result.ok {
            print("SUPABASE CHECK OK — \(result.message)")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("SUPABASE CHECK FAIL — \(result.message)\n".utf8))
            exit(1)
        }
    }
}
