import Foundation

/// Headless probe for the Haiku layout engine (run with `--probe-layout-engine`).
/// Runs one real `claude -p` generation against a sample profile and prints the
/// resolved plan — or reports the fail-closed path. Use on a networked Mac with the
/// `claude` CLI authenticated; in a sandbox it exercises the nil→default fallback.
enum LayoutEngineProbe {
    static func run() -> Never {
        let sample = DataProfile(signals: [
            "total-leads": .high, "by-source": .high, "added-weekly": .high,
            "recent-leads": .high, "by-industry": .high, "location": .high,
            "by-tier": .high, "sentiment-mix": .low,
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var candidate: LayoutPlan?
        Task {
            candidate = await LayoutEngine.generatePlan(profile: sample)
            semaphore.signal()
        }
        // Bounded so the probe can't hang past the engine's own timeout + margin.
        _ = semaphore.wait(timeout: .now() + LayoutEngine.timeout + 10)

        let resolved = LayoutResolver.sanitize(candidate, knownBinds: DashboardBuilder.availableBinds)
        let usedDefault = (candidate == nil) || (resolved == DefaultLayout.plan && candidate != DefaultLayout.plan)

        if let candidate {
            let widgets = candidate.widgets.map { "\($0.type.rawValue):\($0.bind):\($0.size.rawValue)" }
            print("PROBE — Haiku returned a plan: [\(widgets.joined(separator: ", "))]")
            print("PROBE — after validation: \(usedDefault ? "REJECTED → DefaultLayout" : "ACCEPTED")")
        } else {
            print("PROBE — generation returned nil (CLI missing / timeout / error) → DefaultLayout (fail-closed)")
        }
        exit(0)
    }
}
