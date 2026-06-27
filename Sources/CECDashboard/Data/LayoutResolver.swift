import Foundation

/// The if-changed gate. Returns the cached plan when the data profile is unchanged
/// (no regeneration / no LLM call), otherwise calls `generate` and caches the result.
/// `force` bypasses the cache — the manual "Re-layout" override.
///
/// `generate` is the plan source on a miss: the `claude -p` (Haiku) call, which returns
/// `nil` on any failure. The candidate is **validated before caching** (`sanitize`): a
/// nil / empty / unknown-bind plan falls back to `DefaultLayout.plan`, so a hallucinated
/// bind can never be persisted and replayed across launches (no cache poisoning).
///
/// Single-instance assumed: cross-process races are last-writer-wins (atomic write
/// prevents torn files), benign for a local single-user tool.
enum LayoutResolver {
    @discardableResult
    static func resolvePlan(
        profile: DataProfile,
        force: Bool,
        cacheDir: URL = LayoutCache.directory(),
        knownBinds: Set<String> = DashboardBuilder.availableBinds,
        generate: (DataProfile) async -> LayoutPlan?
    ) async -> LayoutPlan {
        if !force, let cached = LayoutCache.load(from: cacheDir), cached.key == profile.key {
            return cached.plan
        }
        let candidate = await generate(profile)
        let plan = sanitize(candidate, knownBinds: knownBinds)
        if !LayoutCache.save(CachedLayout(key: profile.key, plan: plan), to: cacheDir) {
            // Fail-open, but log: a persistently-failing save means we regenerate every
            // time — in step C that's a Haiku call per refresh.
            NSLog("LayoutResolver: layout cache save failed; layout will regenerate next load")
        }
        return plan
    }

    /// Accept a candidate plan only if it's non-nil, non-empty, and every bind is known;
    /// otherwise fall back to the deterministic default. Pure → directly testable, and
    /// the one guarantee that only valid plans ever reach the cache.
    static func sanitize(_ candidate: LayoutPlan?, knownBinds: Set<String>) -> LayoutPlan {
        guard let c = candidate,
              !c.widgets.isEmpty,
              c.widgets.allSatisfy({ knownBinds.contains($0.bind) })
        else { return DefaultLayout.plan }
        return c
    }
}
