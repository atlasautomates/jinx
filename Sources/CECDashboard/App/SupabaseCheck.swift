import Foundation

/// Headless Supabase connectivity check (run with `--check-supabase`).
/// Verifies the Keychain key + a read against every `v_cec_*` view the app
/// consumes (7.2 remap — the reader credential can see exactly these views, so
/// each probe is also a grant check). Run on a networked Mac; it will fail in a
/// sandboxed/offline context (expected).
enum SupabaseCheck {
    /// COMPILE-TIME isolation pin: the Task body below runs while the main
    /// thread blocks on the semaphore, so everything it constructs must stay
    /// nonisolated — a `@MainActor` LeadsRepository or ProfileRepository (and
    /// with them SupabaseClient, which both wrap) would deadlock the wait
    /// into a spurious 20s-timeout FAIL. This nonisolated function fails to
    /// compile the moment either constructed type gains `@MainActor`.
    /// (Verified non-vacuous: annotating LeadsRepository breaks the build.)
    private nonisolated static func _isolationPin(_ client: SupabaseClient) {
        _ = LeadsRepository(client: client)
        _ = ProfileRepository(client: client)
    }
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
            // ONE Keychain read per item for the whole check: the client AND
            // the expiry decode share them (a second SecItemCopyMatching is
            // unbounded, can prompt, and sat inside the 20s wall). Computed
            // BEFORE the probes so a thrown essential probe can't lose the
            // expiry line — the case where knowing the JWT expired matters most.
            let key = SupabaseConfig.apiKey()
            let anon = SupabaseConfig.anonKey()
            var credLine = "credential: MISSING — no supabase_api_key Keychain item"
            var credExpired = false
            if let key {
                if let expiry = SupabaseConfig.keyExpiry(of: key) {
                    if expiry < Date() {
                        let daysAgo = max(1, Int((-expiry.timeIntervalSinceNow / 86_400)
                                                    .rounded(.up)))
                        credExpired = true
                        credLine = "credential: EXPIRED \(daysAgo)d ago — re-mint the "
                            + "reader JWT (mint_class_jwts.py --only read_cec) and "
                            + "re-seed the Keychain item"
                    } else {
                        let days = Int(expiry.timeIntervalSinceNow / 86_400)
                        credLine = "credential: expires in \(days)d"
                            + (days < 30 ? " — RE-MINT SOON" : "")
                    }
                } else {
                    credLine = "credential: no exp claim readable (not a JWT?)"
                }
            }
            // APPEND, never assign: this line must survive the expiry reading
            // above, or the one state it names prints "expires in 359d" under
            // a FAIL — a green-reading diagnostic in a broken state (delta
            // round 5: the assign form was dead code, clobbered every time).
            if key != nil && anon == nil {
                credLine += "\n  credential: supabase_anon_key is MISSING — the "
                    + "gateway key must ride the apikey header (seed it; see "
                    + "install-mac.sh's CREDENTIAL ORDER note)"
            }
            do {
                guard let key, let anon else { throw SupabaseClient.ClientError.missingKey }
                let client = SupabaseClient(baseURL: SupabaseConfig.restURL,
                                            anonKey: anon, bearerKey: key)
                let repo = LeadsRepository(client: client)
                // Independent probes fan out CONCURRENTLY: sequential reads
                // could exceed the 20s wall on a slow-but-healthy network and
                // read as a broken install (reliability + platform reviews).
                // NOTE: leadsProbe exercises the REAL essential select (the full
                // leadColumns incl. the axis tail) — ping()'s id-only read would
                // stay green while a missing view column 400s the whole Leads tab.
                // ONE-ROW READABILITY probes, not maxPages:1 walks: a capped
                // walk's ok flag is true only on an EMPTY page, so a healthy
                // non-empty table printed READ FAILED while a grant blackout
                // printed clean — inverted in both directions (reliability
                // review, 7.2).
                async let leadsProbeTask = repo.recentLeads(limit: 1)
                async let repliedOKTask = repo.repliedProbe()
                async let sentOKTask = repo.sentEventsProbe()
                // The search select (extra columns + the or= grammar) and the
                // count path (Prefer: count=exact + Content-Range parsing) are
                // DIFFERENT request shapes from the walks — each has failed
                // independently before (p7a4's full_name hotfix; the install
                // acceptance rides the count).
                async let searchTask = repo.search("zz", limit: 1)
                async let countTask = repo.totalCount()
                // Profile sheet reads: the dossier view + the timeline view.
                let profileRepo = ProfileRepository(client: client)
                async let profileTask = profileRepo.profileProbe()
                async let interactionsTask = profileRepo.fetchProbe()

                let leadsProbe = try await leadsProbeTask           // essential
                let repliedOK = await repliedOKTask
                let sentOK = await sentOKTask
                let searchOK = (try? await searchTask) != nil
                let total = try? await countTask
                let profileOK = await profileTask
                let interactionsOK = await interactionsTask

                // Every reader-boundary probe folds into the EXIT CODE: a
                // half-broken install must not print OK (reliability review —
                // the check used to exit 0 with four grants missing). The
                // credential's expiry — the app's Keychain copy is the ONE
                // copy nothing else measures; ce doctor deliberately WARNs on
                // the env twin — folds in too.
                let allOK = repliedOK && sentOK && searchOK && total != nil
                    && profileOK && interactionsOK && !credExpired
                result.ok = allOK

                var lines: [String] = []
                lines.append("leads: \(leadsProbe.count) row sampled (full v_cec_leads "
                    + "select incl. status axes), count=\(total.map(String.init) ?? "FAILED"), "
                    + "search \(searchOK ? "OK" : "FAILED")")
                lines.append("kpi: replied probe \(repliedOK ? "OK" : "FAILED"), "
                    + "sent-events probe \(sentOK ? "OK" : "FAILED")")
                lines.append("profile: v_cec_lead_profile \(profileOK ? "OK" : "FAILED"), "
                    + "v_cec_lead_interactions \(interactionsOK ? "OK" : "FAILED")")
                lines.append(credLine)
                if !allOK {
                    lines.append("one or more reader-boundary reads FAILED — "
                        + "re-apply migrations/2026-08-16_p7a5_view_semantics_and_probe_v26.sql "
                        + "and check the Keychain credential")
                }
                result.message = "reached \(client.baseURL.host ?? "supabase")\n  "
                    + lines.joined(separator: "\n  ")
            } catch {
                // The credential line survives a thrown essential probe.
                result.message = error.localizedDescription + "\n  " + credLine
            }
            semaphore.signal()
        }
        // init() blocks the main thread on this wait, so the Task body above must stay
        // off the main actor (pure networking + Keychain) or its continuation would
        // deadlock against this wait. Bounded so the probe can never hang
        // indefinitely. The isolation requirement is enforced BY THE COMPILER
        // via `_isolationPin` at the top of this enum.
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
