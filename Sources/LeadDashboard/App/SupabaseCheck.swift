import Foundation

/// Headless Supabase connectivity check (run with `--check-supabase`).
/// Verifies the Keychain key + a read against `leads`. Run on a networked Mac;
/// it will fail in a sandboxed/offline context (expected).
enum SupabaseCheck {
    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        var message = "unknown"

        Task {
            do {
                let client = try SupabaseClient.make()
                let sampled = try await LeadsRepository(client: client).ping()
                ok = true
                message = "reached \(client.baseURL.host ?? "supabase"), \(sampled) row(s) sampled"
            } catch {
                message = error.localizedDescription
            }
            semaphore.signal()
        }
        // init() blocks the main thread on this wait, so the Task body above must stay
        // off the main actor (pure networking + Keychain) or its continuation would
        // deadlock against this wait. Bounded so the probe can never hang indefinitely.
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            FileHandle.standardError.write(Data("SUPABASE CHECK FAIL — timed out after 20s\n".utf8))
            exit(1)
        }

        if ok {
            print("SUPABASE CHECK OK — \(message)")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("SUPABASE CHECK FAIL — \(message)\n".utf8))
            exit(1)
        }
    }
}
