import Foundation

/// The if-changed gate. Returns the cached plan when the data profile is unchanged
/// (no regeneration), otherwise calls `generate` for a fresh plan and caches it.
/// `force` bypasses the cache entirely — the manual "Re-layout" override (step C).
///
/// `generate` is the plan source on a miss: step B passes `DefaultLayout.plan`;
/// step C will pass the `claude -p` (Haiku) call. Keeping it a closure means swapping
/// in the LLM is a one-line change and the gate stays identically tested.
///
/// Single-instance assumed: cross-process races are last-writer-wins (atomic write
/// prevents torn files), benign for a local single-user tool.
///
/// ⚠️ STEP C: before saving an LLM-generated plan, validate its binds against the
/// known data series and fail closed to `DefaultLayout.plan` on any violation — never
/// persist an unvalidated plan, or a hallucinated bind gets replayed across launches.
enum LayoutResolver {
    @discardableResult
    static func resolvePlan(
        profile: DataProfile,
        force: Bool,
        cacheDir: URL = LayoutCache.directory(),
        generate: (DataProfile) -> LayoutPlan
    ) -> LayoutPlan {
        if !force, let cached = LayoutCache.load(from: cacheDir), cached.key == profile.key {
            return cached.plan
        }
        let plan = generate(profile)
        if !LayoutCache.save(CachedLayout(key: profile.key, plan: plan), to: cacheDir) {
            // Fail-open, but log: a persistently-failing save means we regenerate every
            // time — harmless now, but in step C that's a Haiku call per refresh.
            NSLog("LayoutResolver: layout cache save failed; layout will regenerate next load")
        }
        return plan
    }
}
