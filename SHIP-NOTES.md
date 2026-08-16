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

---

# Campaigns drill-down revamp — SHIP notes (2026-08-05)

Replaces the Campaigns tab's widget dashboard + Palette-styled inspector with a
three-level drill-down on the AB design system (design brief:
`.claude/design/briefs/campaigns-drilldown.md`): campaign list (status on row) →
campaign's leads → per-lead correspondence, including STAGED sends. Adds the
app's first and only write path: posting copy revisions to staged sends.

## Data model (all reads anon/GET-only)

- **Level 1** — existing `CampaignsRepository.fetch()` compose (campaigns +
  campaigns_tracking + campaign_leads + send_queue), unchanged semantics.
  `CampaignDashboardViewModel.state` is now `Loadable<CampaignInputs>` (the
  `Dashboard` widget build + `CampaignBuilder` are deleted).
- **Level 2** — existing `roster(campaignId:)` (campaign_leads ⟕ leads).
- **Level 3** — new `correspondence(campaignId:leadId:)`:
  `lead_interactions` (lead-scoped, newest-first cap+1 at 500) merged with
  `send_queue` scoped to (campaign, lead). Pure seam `composeCorrespondence`
  (SelfTest-pinned): sent queue rows whose `queue_id` appears in an archived
  interaction's metadata dedupe out (the archive is richer); pending rows render
  as STAGED (dashed); failed/skipped labeled; unarchived sent rows render
  compactly. Ascending by parsed date, id tiebreak. Metadata reads go through
  `LeadInteractionRow.meta` (handles the double-encoded jsonb shape).

## Data honesty

- Interaction archive for outbound sends is subject-only (ce-outbound writes no
  transcript): cards say the copy is the pool template rather than faking a body.
- `campaign_sequences` has NO anon SELECT — staged copy from the pool template is
  labeled "not readable with the dashboard key", never fabricated.
  `subject_override`/`body_override` render when present ("revised" pill).
- Failed queue rows say "copy is the step's pool template", never "sent".
- Degraded reads caption themselves: partial level-1 compose, truncated roster,
  failed name join, one-sided correspondence reads, truncated history,
  missing write key (read-only hint).
- `lead_interactions` has no campaign column: the timeline deliberately shows
  the lead's WHOLE history; rows whose metadata names a different campaign are
  tagged "other campaign".

## The write path (scope revision, user-directed 2026-08-05)

- `SupabaseWriteClient` — the ONE write seam. Separate Keychain item
  (`supabase_write_key`, same service); absent → editor degrades to read-only
  with the grant command. Read client stays GET-only (comment updated to point
  here; never add writes there).
- Exactly one operation: PATCH `send_queue` `subject_override`/`body_override`
  by PRIMARY KEY + `status=eq.pending` + `claimed_at=is.null`. A row the sender
  claimed (`status='sending'`) or finished can never be rewritten; 0 matched
  rows surfaces as "no longer editable". PostgREST ignores `limit` on PATCH
  (pinned in ce-outbound), so the id filter is the guard, not a nicety.
- Overrides are ce-outbound's existing VIP mechanism: the sender prefers them
  over the pool template and still substitutes `{{merge}}` slots; the editor
  says so. Emptying both fields writes NULLs = back to the pool template.
- No RLS/policy changes: anon stays read-only server-side. The write key is
  device-only in the Keychain, ACL-bound to the signed app.

## UI

- `Views/ABCampaigns/`: `ABCampaignsView` (root, breadcrumb, level transitions,
  L1 table), `ABCampaignLeads` (L2), `ABCorrespondence` (L3 + editor),
  `ABCampaignsFixture` (frozen harness data). `CampaignDrillModel` carries the
  drill state with the house newest-wins generation guard; `saveRevision`
  re-checks the generation before its post-save reload.
- `ABStatusPill` gained an `init(text:role:)`; `ABLoadingView`/`ABErrorView`
  gained a `noun` (defaults keep Leads call sites).
- Harness: `campaigns` / `campaign-leads` / `campaign-thread` registered on the
  fixture; `TextEditor` (NSTextView-backed) is gated off `isStaticRender` so
  stills render the draft as text. Layout gotcha pinned in-code: a width-only
  `Color.clear` in a header row is vertically greedy and spreads the table.
- Deleted: `CampaignBuilder.swift`, `CampaignInspectorView.swift` (+ their
  SelfTest widget checks, replaced by compose/funnel/cardLabel checks).

## Known gaps (deliberate)

- Staged pool-template copy can be OVERRIDDEN but not viewed (no anon read on
  campaign_sequences); revising replaces the template blind. Honest label in UI.
- Editing is conservative: a stale `claimed_at` from a crashed sender blocks the
  edit until the watchdog clears it — fail-closed beats racing the sender.
- No editor-open preview still (`editingId` is view-local @State); the editor is
  exercised live, its closed-state affordance is in `campaign-thread`.

## Review response (7 pinned lenses + 2 ad-hoc: sender-contract, drill-state-machine)

Nine parallel reviewers; no CRITICALs. Every HIGH/MEDIUM fixed and pinned in
`--selftest` where a pure seam exists:

- **Sender-contract HIGHs**: `RevisionLint` refuses drafts the sender would
  corrupt — unknown/malformed `{{slots}}` (would ship literal braces; the
  sender's leftover-check regex misses spaced/digit variants) and
  non-atlasautomates links (`_defang_links` strips them silently). Pinned.
- **PostgREST 1000-row cap** (code+reliability HIGH, pre-existing):
  `campaignLeads()` now pages with short-page termination like `roster()`; the
  dead-probe windowed read and the consumerless `sendQueueRows`/`sendsByAccount`
  fetch are gone.
- **meta() numeric jsonb** (QA MEDIUM, failing driver): `.number` values now
  surface; selftest fixture uses the producer's numeric shape.
- **Timeline identity** (swift M1): interaction ids derive from the selected PK
  (`order=interaction_at.desc,id.desc`); roster dedupes duplicate lead_ids.
- **Write response three-way** (3×MEDIUM): parse-failure → `.unconfirmed`
  ("may have landed — refresh"), never `.rowNotEditable`.
- **Write hardening** (security): UUID allowlist on the id (sender parity),
  subject control-char strip (bare-\n malformed-header class, verified against
  smtp_send.py), guard-triple + sanitizer + lint pinned in selftest, os.Logger
  audit trail (hashed queue id, lengths only), attributes-only Keychain probe.
- **Drill state machine** (F1/F2/F5/F6): save-success closes only the saved
  card's editor + revise buttons disabled while saving; `refreshLevel()` gives
  levels 2/3 a real in-place refresh (header button + 10-min tick) and
  re-resolves the lead pill; `revisionError` cleared on navigation/editor-open;
  `.rowNotEditable` now reloads the thread so the stale Staged card snaps to
  reality; breadcrumb + vanished-campaign caption route through the live list.
- **Bounce/legacy contract** (sender F5/F6/F7): failed-with-archive renders
  "Bounced" (never "never sent"); legacy sent rows fuzzy-dedupe (step + Δt<180s);
  `sending` labeled in-flight; step-1 `variant_index` labeled as angle A/B/C,
  later steps "attributed", never "variant".
- **Platform**: stateful `pointingCursor` (onDisappear pop), rows are real
  Buttons (keyboard/VoiceOver), POSIX date locales, CWE-134 NSLog "%@" fixes,
  `--check-write-key` acceptance step in install-mac.sh, `campaign-thread-editing`
  harness still (caught the ungated subject TextField at 19,808 yellow px).

**Accepted (recorded, not fixed)**: superseded drill loads keep paging (bounded
10×15s, generation guards correctness — no cancellation plumbing yet); the
service-key-in-Keychain write credential stands per security review ("does not
meaningfully widen" the existing `.env` exposure; anon-UPDATE correctly
rejected) with a **follow-up**: move the write behind a Modal bearer-auth
endpoint so the pending/claimed guards become server-enforced. Subject
whitespace normalization mirrored sink-side in smtp_send.py is deferred to the
next coordinated Modal redeploy (client-side strip covers the only new writer).

# Leads-only remap onto the v_cec_* reader boundary — SHIP notes (2026-08-16)

leads-domain-split task 7.2 (plan: `.claude/plans/leads-db-domain-split.md`).
Adrian's ruling: Leads tab ONLY; Pipeline (unused) + Campaigns (write access;
may return as its own app) DEPRECATED — deleted, not hidden, because under the
reader credential their table reads have no data source.

- **Credential**: Keychain `supabase_api_key` now holds the `arcane_read_cec`
  JWT (SELECT on exactly the six `v_cec_*` views). The `supabase_write_key`
  item (write key, staged-copy revisions) lost its last consumer — the
  revision editor left with the Campaigns tab; delete the Keychain item.
- **Leads book**: `leads` → `v_cec_leads` (same keyset walk). `enrichment_stage`
  retired; the select adds `outreach,deepening,personalized,has_research,
  status_row_missing`. Lane = `deepening ≠ 'none'` / the view's guarded-copy
  `personalized` boolean — per-row, so the lane can no longer degrade
  independently (ABUnavailableChip + `lanesDegraded` machinery deleted).
- **Emailed truth** = `v_cec_sent_events` membership (the permanent
  lead_interactions log), NOT the `outreach` axis (45-lead divergence, open
  finding) and NOT the swept `send_queue` (chart was blank; ~16wk of history
  restored). The walk is UNWINDOWED so the emailed KPI is all-time; the trend
  windows locally.
- **Status panel** is now a stage FUNNEL (Scraped=all, Researched=has_research,
  Personalized=personalized, Campaigned=sent-set) — overlapping by design,
  rendered in stage order. Row status uses the same furthest-stage derivation.
- **Replied set** = `v_cec_lead_interactions` `direction=eq.inbound` (id-keyset).
- **Profile** = ONE `v_cec_lead_profile` read (lead + generated halves are two
  decodes of the same response; all-NULL generated → nil so the Personalization
  card suppresses) + `v_cec_lead_interactions` timeline. Source/Status/Tier
  facts and the tier badge retired; `web_research_json` → `research`.
- **Voice**: `--query by-tier` and the Siri tier dimension retired
  (lead_tier is gone; runtime score_lead is the only tier source).
- **Deleted**: Campaigns/Pipeline/Backlog views+repos+models, widget grid
  (Widgets/, Grid/, Shell/, Dashboard/Layout/Packer/MockData), write path
  (SupabaseWriteClient, RevisionLint, `--check-write-key`).
- Verified: `swift build` clean, `--selftest` PASS, stills render
  (leads/leads-filtered/profile), residual grep for dead surfaces = 0 hits.

## 7.2 review-round fixes (2026-08-16, same session)

Seven reviewers (code/qa/reliability/macos/swift-semantics/design + a
view-contract lens) → one fix batch:

- **Replied set** scoped to `interaction_type=eq.email` (a Cal booking or
  magnet view is not a reply); `leadIDsResult` takes a filters array.
- **Search**: facets now resolve whenever a resolver exists — the default
  no-filter state was rendering campaigned hits as "Personalized" (QA
  regression). Search select carries `full_name` (107 live divergences).
- **Row labels**: promoted to "Replied" via the replied set (pink reward role
  reachable again); under a FAILED sent-events read every emailed test falls
  back to the `outreach` axis (an empty event log is a failure, not "nobody
  emailed") — this is what finally consumes the axis column. `status_row_missing`
  counts into a filter-bar disclosure.
- **Funnel** retitled "Stage funnel" + per-row retention share of Scraped —
  overlap semantics legible next to the true partitions; frozen `ab` fixture
  rewritten to the shipped vocabulary (6 stills were rendering deleted UI).
- **--check-supabase** rewritten: one-row readability probes (the maxPages:1
  walks inverted ok in both directions), ALL probes fold into the exit code,
  + search/count-path probes + credential-expiry decode (FAIL when expired,
  warn <30d — the app's Keychain copy is the one copy ce doctor can't see).
- **Voice**: `breakdownWindow` = the PostgREST 1000 cap and `sampled` compares
  against the real total (the caveat was unreachable); tier retired from the
  Aris gate allow-list + tool description (it reported the dead metric as a
  database outage) and from app-access's worked examples.
- **install-mac.sh**: credential-order preflight documented (swap Keychain
  FIRST), acceptance = exit code + anchored `^You have [0-9]+ leads\.$`, and
  the rollback re-verifies the previous build before calling it live.
  `project.yml` versions bumped to 3 (App Intents surface changed).
- **Swift 6 hygiene**: DateParse → `Date.ISO8601FormatStyle` (Sendable; the
  shared ISO8601DateFormatter statics were a compiler-verified data-race
  error), `refreshOnWake`'s task group → two `.task` children, `Window` scene
  (⌘N duplicated pollers and forked the pins file), stored cancel-and-replace
  refresh task, LeadQuery locals → locked box, `@Sendable` client factory.
- **Profile**: enrichment decode `try?` (one malformed research payload took
  down the whole dossier), Personalization card gated on real content
  (research-only leads got an empty card), `casualized_shape` corruption
  surfaced as a fact, opener/offer blocks = the sheet's one accent moment.
- **Pins**: `.claude/tests/test_cec_view_contract.py` (7 tests, 3 mutations
  killed) — Swift selects ⊆ view DDL, Aris `_LEAD_METRICS` ⊆ binary metrics,
  breakdownWindow = page cap. SelfTest: stage-ladder pins incl. Replied +
  degraded-axis fallback + clean-empty non-fallback, emailed-aware narrow
  resolver + no-filter coverage, timeout = failure, pasteboard restored.
  util-iterate registry `test_hint` now runs `--selftest` (swift test was a
  no-op — no test target).

Accepted/deferred with rationale: sentEvents per-row type-mismatch stays
skip-and-count (PostgREST cannot emit non-string for these view columns;
defensive only). Lane labels vs funnel "Personalized" naming kept — lane
`standard` EXCLUDES deep leads, funnel Personalized includes them; not one
boolean. KPI "≥" floor rendering superseded by the axis fallback (the KPI now
approximates under degradation instead of flooring to zero; chip names the
read). key rotation is tracked on the private plan;
`supabase_write_key` Keychain deletion is an install-step of this change.

### Round-2 fixes (delta r1 + headless-contention lens, same session)

- RevisionLint pins RETIRED with inverted tombstones (ce doctor names the
  retirement — never a silent skip — and FAILs if the file reappears without
  the reconciliation; same inversion in test_one_method_pins). Battery 167/167.
- Two behavioural pins added + mutation-proven: fetch() must send BOTH
  replied-set predicates over the wire (stub-request assertion), and the
  ABLeadsData half of the axis fallback (emailed KPI / funnel Campaigned /
  replies under a failed sent-events read).
- Intents deadline made REAL: Keychain.exists preflight + leakable-GCD-thread
  race via continuation (the task group awaited the orphaned SecItemCopyMatching
  — proven with a compiled repro; Siri hung past its own timeout).
- LeadProfileModel's Keychain read hoisted off the main actor (the one seam
  the other view models' hoists never covered).
- --check-supabase: ONE Keychain read shared by client + expiry decode,
  credential line computed before the probes (survives a thrown essential
  probe), expired folds into exit code, ceil'd days. Compile-time isolation
  pin replaces the "enforced by review" wish.
- Wake/activation throttle floors on lastAttemptAt (was vacuous while loads
  failed); requestLoad = generation-guarded + TaskBox deinit cancel;
  --fixture pins point at a per-run scratch dir (live-network seam closed);
  activate() no longer force-steals focus on background intent launches;
  CECAppDelegate makes Dock-reopen explicit for the single Window scene;
  LeadQuery validates the metric BEFORE the Keychain read (pre-validation set
  pinned equal to the answer switch); install-mac.sh warns when the quit
  request is denied; corrupt generated decode logs + marks the dossier
  partial with its own banner wording.
- MANUAL VERIFY AT INSTALL: launch → ⌘W → click the Dock icon; the window
  must come back (Window-scene reopen; delegate fallback added but the
  behavior wants one real click).

### Install-time catch: the two-key wire contract (2026-08-16)

First install attempt FAILED acceptance (and the new both-builds-broken
rollback message earned its keep on its first firing): the app sent the ONE
Keychain value as both `apikey` and the bearer — and Supabase's gateway
validates `apikey` against KNOWN keys, so the reader JWT there is a hard 401
before PostgREST runs. This is 6.1 intel the PYTHON factory already encodes
(apikey = anon, class JWT rides only the bearer) and every review lens missed
on the Swift side. Fix: two Keychain items (`supabase_api_key` = reader JWT →
bearer; NEW `supabase_anon_key` = anon key → apikey header), fail-closed when
either is absent, `--check-supabase` names a missing anon item, Intents
preflights both, installer note updated. PINNED behaviourally: the selftest
asserts on a captured wire request that apikey carries the anon value and
Authorization carries the bearer — the mirror of the Python factory's
AuthMechanism pins. Second install: acceptance PASSED ("You have 3455
leads."), live `--check-supabase` all-OK with `credential: expires in 359d`.
