# Leads tab reskin — SHIP notes

Turns the approved Variant-C Leads tab (fixture-only) into the PRODUCTION Leads tab:
live Supabase data, Loadable states, no behavior regressions. The frozen design is
unchanged — the `--screenshot` harness renders byte-identical PNGs (md5-verified
against the committed `AB-ARM/previews/*`).

## What got wired

**Live data path.** `RootView.leadsTab` now renders `ABLeadsView` from the live
`DashboardViewModel` pipeline (Supabase → `LeadsRepository.fetch()` →
`DashboardInputs` → `ABLeadsData(inputs:)`). The VM's `state` changed from
`Loadable<Dashboard>` to `Loadable<ABLeadsData>`. The harness path still constructs
`ABLeadsView(data: .ab)` with fixture data and no network — same view code, two data
sources.

**Mapping layer.** `ABLeadsData.init(inputs: DashboardInputs)` (in `ABLeadsFixture.swift`)
is pure, total, no force-unwraps. All divisors guarded. Documented decisions below.

**Loadable states.** New AB-styled `ABLoadingView` / `ABErrorView` / `ABStaleBanner`
(`Views/ABLeads/ABStateViews.swift`, DesignTokens only). `leadsTab` switches on
`model.state`: idle/loading → loader, loaded → live view, stale → live view + banner,
failed → error view with Retry. Never a blank black screen; never a crash on empty.

**No behavior regressions.**
- Recent-lead row click → opens the shared lead profile. `ABLeadRow` gained an
  `onSelect` closure; the live tab wires it to `profilePresenter.active =
  LeadRef(id:companyName:email:nil)` — the same idiom the deleted `RecentLeadsList`
  used. Fixture rows carry no DB id → inert (harness is a still).
- `PinnedStrip` retained and restyled onto DesignTokens (flat/compact, teal identity,
  hover feedback). Pins still render and open profiles.
- Refresh: header refresh control (`ABRefreshButton`) appears only in live mode
  (`onRefresh != nil`), re-fetches via `model.load()`, spins while in flight.
- The 10-min `periodicRefresh()` in RootView already fanned out to `model.load()`;
  now that `model` drives the live tab, it is a genuine data refresh. Its misleading
  comment ("both use fixed deterministic layouts, so this is a pure data refresh") was
  corrected.

## Mapping decisions (live pipeline → frozen ABLeads shape)

| ABLeads field | Source | Notes |
|---|---|---|
| `totals.scraped` | `DashboardInputs.totalCount` | exact full-table lead count |
| `totals.emailed` | `statusCounts["campaigned"]` | **proxy** — distinct leads that reached the `campaigned` enrichment stage (= added to an outbound campaign). Exact full-table when present; else a windowed count of `enrichment_stage == campaigned` over the fetched leads. See gap #1. |
| `totals.replies` | distinct `replies.lead_id` (new deduped tally) | distinct **replied leads** — same lead grain as `emailed`, so the reply rate can't exceed 100% on multi-reply threads (was reply-event count; fixed per review F1). |
| `emailedOfScrapedPct` | `percent(emailed, of: emailedDenominator)` | guarded: 0 denominator → 0, never NaN. Denominator = exact total normally, fetched window in the degraded fallback (F7). The KPI bar fill is clamped to [0,1] so any ratio can't overrun its track (F1). |
| `repliesOfEmailedPct` | `percent(replies, of: emailed)` | guarded; both operands are distinct leads |
| `leadsAddedWeekly` | fetched leads `created_at`, 12-week window anchored to `now` | shared clock-anchored axis (F4); out-of-window/outlier dates are ignored, not window-shifting |
| `leadsMessagedWeekly` | `send_queue` (`status=sent`, `lead_id`+`sent_at`, last 13 wks) | counts **distinct leads per week** (deduped by `lead_id`), same grain + same 12-week `now`-anchored axis as `leadsAddedWeekly` (fixed per review F3/F4). |
| `bySource` / `byIndustry` | fetched leads, top 6 + "Other" | windowed over the fetched leads |
| `byStatus` | exact `statusCounts` (enrichment_stage) labelled; else windowed rollup | stage vocabulary, not the mock's Emailed/Replied/Bounced set. See gap #4. |
| `recentLeads` | first 50 fetched leads | carries the DB `id` (for profile-open) + display fields; nil company → "Unknown", nil city/state → "—" |

New `DashboardInputs` fields (additive, defaulted — no existing consumer breaks):
`replyCount` (distinct replied leads), `messagedSends` (`[SentEvent]` = lead+sentAt).
New `LeadsRepository` reads: `replyCountResult()` (distinct `replies.lead_id`),
`messagedSendsResult()` (`send_queue` lead_id+sent_at) — both **fail-open** (empty/0
on error), wired through `fetch()`/`compose()`. No schema changes; all reads are anon
read-only PostgREST via the existing `SupabaseClient` (`get`/`count`).

## Metric gaps (data-honesty — NOT fabricated)

1. **"Emailed" is the `campaigned` enrichment stage, not a per-send fact** (ACCEPTED
   proxy). A lead in the `campaigned` stage is enrolled in outreach; a queued-but-
   unsent lead counts. This is the cleanest *distinct-lead* funnel signal available
   without an awkward PostgREST distinct-count over `send_queue`. `campaigned ⊆ total`,
   so `emailedOfScrapedPct ≤ 100%` always.
2. **`byStatus` uses the pipeline-stage vocabulary** (Scraped/Researched/Personalized/
   Campaigned/Unknown), not the mock's richer Emailed/Replied/Bounced/DNC set — those
   aren't `enrichment_stage` values, and the same applies to the recent-leads status
   column. Populating engagement status per lead would require N per-lead reply/bounce
   joins; out of scope for this ship, and relabeling the board would break the frozen
   fixture. ACCEPTED + documented (review F5). `ABStatusRole` maps `campaigned →
   active` (teal) so outreach still reads in the two-accent language; the pink reply
   role stays visible via the reward KPI + the pink trend.
3. **`send_queue` messaged read is bounded** to the most-recent 1000 sends within 13
   weeks (`sent_at.desc`), so the right (recent) edge of the 12-week trend is always
   complete; a >~77-distinct-leads/week older week could truncate at the left edge.
   Current volume (249 distinct leads across the window) is well under the cap.
4. **Source/industry breakdowns + the added trend are windowed** over the fetched
   leads (limit 1000, most-recent). Now **disclosed**: source/industry panels carry a
   "N of M" scope note when the window is smaller than the total (review F2); byStatus
   uses exact full-table counts (no note).

Resolved in review (see below): reply-rate now distinct replied leads (F1), messaged
trend distinct leads/week on a shared clock-anchored axis (F3/F4), windowed-fallback
ratio grain (F7), KPI-bar clamp (F1).

Live-verified against real Supabase (`--check-supabase`): distinct `replied-leads=2`,
`send_queue ≤13wk = 466 sends to 249 distinct leads` — all reads succeed under the
anon key.

## Review response (7-lens team + ad-hoc funnel-honesty lens)

All pinned lenses returned APPROVE / SHIP-WITH-FOLLOWUPS; the ad-hoc funnel-honesty
lens gated on 2 HIGH. Fixed before ship:

- **F1 (HIGH) reply-rate scope + bar overflow** — numerator is now DISTINCT replied
  leads (`replies.lead_id` deduped), same grain as `emailed`; KPI bar fill clamped to
  [0,1]. Corroborated by code-reviewer (MEDIUM) + reliability (LOW).
- **F2 (HIGH) undisclosed windowing** — source/industry panels now show a "N of M"
  scope note (restores the disclosure the reskin had dropped vs `DashboardBuilder`).
- **F3 (MED) messaged unit mismatch** — trend counts distinct leads/week (dedup by
  `lead_id`), matching the "Leads messaged" label and the added-trend grain.
- **F4 (MED) misaligned axes** — both trends share ONE 12-week window anchored to
  `now`, zero-filled; also fixes reliability R08 (outlier can't shift/blank the chart)
  and the code-review LOW (520-cap wrong-tail).
- **F7 (MED) fallback grain** — the windowed-emailed fallback now uses a windowed
  denominator (`emailedDenominator`) so the hero ratio stays leads/leads at one grain.
- LOWs: `statusBreakdown` Dictionary trap → `uniquingKeysWith` (QA); "Other" label
  collision → merge-dedupe (code-review); stale banner moved off the reward-pink hue
  to the amber `statusRed` family (design MED); spin duration → `ABMotion.spin` token
  (design MED).

Accepted with rationale (not fixed): F5/gap #2 (status vocabulary — frozen-design
conflict + per-lead-join cost); F6/gap #1 (emailed = campaigned proxy); reliability
R02 (no transient-retry on essential reads — degrades to `.stale`/Retry, bounded) and
R07 (the `partial` flag is inert on this tab because ABLeads renders neither tier nor
sentiment; supplementary degradation is fail-open by policy). All pinned in
`SelfTest.abLeadsMappingChecks()` where deterministic.

## Divisor-guard bug class (fixed + pinned)

The reviews flagged `values.max() ?? 1` not covering the all-zero case (0/0 → NaN →
broken bar/plot geometry). Fixed at both sites:
- `ABBreakdownPanel.maxCount` → `max(1, … ?? 1)`
- `ABTrendChart.peak` → `max(1, … ?? 1)`
- `ABLeadsData.percent(_:of:)` is the single guarded choke-point for both KPI ratios.

Pinned by `SelfTest.abLeadsMappingChecks()` — asserts empty/all-zero inputs yield 0%
ratios (never NaN), empty series/lists, funnel math, DB-id carry-through, nil-field
tolerance, and the empty-statusCounts fallback.

## Cleanup

- Deleted `Views/RecentLeadsList.swift` (only caller was the dead `leadsSplit`; not
  used by Campaigns/Pipeline).
- Removed the dead `RootView.leadsSplit(...)` helper and stale legacy comment.
- `DashboardViewModel` slimmed (dropped unused `recentLeads`/`totalLeads` props).
- `DashboardBuilder` is **retained** — it's still exercised by ~12 SelfTest assertions
  and is Leads-dashboard reference logic; not deleted to avoid gutting test coverage.
  It is no longer on the render path.
- `AB-ARM/` is left in place (won't merge) and is not referenced from app code.

## For reviewers to scrutinize

- **Funnel-math honesty** — the emailed/replies/messaged proxies above (gaps #1–#3):
  are the chosen sources the right honest defaults, and are the SHIP-NOTES labels the
  ones the UI should imply?
- **Divisor guards** — any remaining `/ 0` or NaN path in chart/bar geometry beyond the
  two fixed sites.
- **Harness identity** — confirm the live-mode optional params (onSelectLead/onRefresh/
  isRefreshing/staleMessage) truly can't perturb the fixture render (md5 identical, but
  verify the reasoning: all default nil/false; header button + stale banner are behind
  `if let`).
- **`send_queue.sent_at` read** — cutoff string format, `status=eq.sent` filter, the
  1000-row bound, and the null-`sent_at` compactMap.
- **Concurrency** — `ABLeadsData(inputs:)` is pure/@Sendable-safe; the VM stays
  @MainActor; the SupabaseCheck probes stay off the main actor (pinned).

## Build / test / live

- `swift build` — clean.
- `--selftest` — PASS (incl. new `abLeadsMappingChecks`).
- `--screenshot leads` / `leads-detail` — render deterministically; **md5-identical**
  to committed `AB-ARM/previews/*` (design provably unchanged).
- `--check-supabase` — OK; new reply/send_queue probes succeed live.
- GUI not launched.
