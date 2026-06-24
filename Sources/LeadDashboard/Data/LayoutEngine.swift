import Foundation

/// Generates a layout plan by invoking `claude -p` (Haiku) as a subprocess.
///
/// Returns `nil` on ANY failure — CLI not found, timeout, non-zero exit, unparseable
/// output. It never throws; the resolver validates the result and falls back to
/// `DefaultLayout.plan`. Run from a temp cwd (NOT the repo) with `--system-prompt`
/// replacing Claude Code's default, so Haiku's context stays tiny and cheap.
enum LayoutEngine {
    static let model = "claude-haiku-4-5"
    static let timeout: TimeInterval = 25

    /// Try once, then (on a parse failure only) one repair retry — caps cost at ≤2 calls.
    static func generatePlan(profile: DataProfile) async -> LayoutPlan? {
        guard let claude = resolveClaudePath() else { return nil }
        let system = LayoutPrompt.systemPrompt
        let base = LayoutPrompt.userPrompt(profile: profile)

        for attempt in 0..<2 {
            let user = attempt == 0
                ? base
                : base + "\n\nYour previous reply did not parse. Output ONLY the JSON object — no prose, no code fences."
            guard let output = await runClaude(path: claude, system: system, user: user) else {
                return nil   // transport failure (missing CLI / timeout / crash) — don't retry
            }
            if let plan = parsePlan(fromEnvelope: output) {
                return plan
            }
            // else: parsed envelope but bad plan JSON → loop once for the repair retry
        }
        return nil
    }

    // MARK: - Subprocess

    private static func runClaude(path: String, system: String, user: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = [
                "-p", user,
                "--model", model,
                "--output-format", "json",
                "--system-prompt", system,
                "--exclude-dynamic-system-prompt-sections",
            ]
            // Run outside the repo so Arcane's CLAUDE.md / skills don't load.
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let stdout = Pipe()
            process.standardOutput = stdout
            // Discard stderr to /dev/null — NOT an undrained Pipe (a full pipe buffer would
            // block the child before exit and force the 25s timeout). We only need stdout.
            process.standardError = FileHandle.nullDevice

            // resume exactly once, whether by completion or timeout.
            let resumeOnce = OneShot()
            process.terminationHandler = { proc in
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8)
                resumeOnce.run {
                    continuation.resume(returning: proc.terminationStatus == 0 ? text : nil)
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce.run { continuation.resume(returning: nil) }
                return
            }

            // Hard timeout: terminate the process AND resume directly — don't rely on the
            // terminationHandler firing (if `claude` ignored SIGTERM we'd hang forever).
            // OneShot makes whichever path wins the sole resumer.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()   // SIGTERM
                    // Escalate to SIGKILL if it's still alive shortly after — no orphan.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                resumeOnce.run { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - Parsing

    /// Parse the `claude --output-format json` envelope → `.result` text → the plan JSON.
    static func parsePlan(fromEnvelope output: String) -> LayoutPlan? {
        guard
            let data = output.data(using: .utf8),
            let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (env["is_error"] as? Bool) != true,
            let resultText = env["result"] as? String
        else { return nil }

        guard
            let planData = extractJSONObject(from: resultText).data(using: .utf8),
            let plan = try? JSONDecoder().decode(LayoutPlan.self, from: planData)
        else { return nil }
        return plan
    }

    /// Strip markdown fences and isolate the outermost `{ ... }` so a fenced or
    /// chatty reply still decodes (per the learnings JSON-fence handling).
    static func extractJSONObject(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
            return String(s[open...close])
        }
        return s
    }

    // MARK: - CLI resolution

    private static let pathLock = NSLock()
    private static var cachedPath: String?

    /// Find the `claude` binary, memoizing a successful result (the login-shell lookup
    /// is the one unbounded wait in the path; resolve it at most once per launch).
    static func resolveClaudePath() -> String? {
        pathLock.lock()
        if let cachedPath { pathLock.unlock(); return cachedPath }
        pathLock.unlock()

        let resolved = computeClaudePath()
        if let resolved {
            pathLock.lock(); cachedPath = resolved; pathLock.unlock()
        }
        return resolved   // don't cache nil — let a later install be found without relaunch
    }

    private static func computeClaudePath() -> String? {
        // System-managed locations first; the user-writable ~/.local/bin is checked last
        // (defense-in-depth against an attacker-planted binary). Then a login-shell lookup
        // (a GUI .app has a minimal PATH that won't include these).
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return whichViaLoginShell()
    }

    private static func whichViaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

/// Ensures a continuation is resumed exactly once across the completion/timeout race.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
