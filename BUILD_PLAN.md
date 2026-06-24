# Lead Dashboard — Build Plan

Native macOS app (SwiftUI) for viewing lead info from Supabase. The dashboard
**adapts** to whatever lead data it's handed: an LLM decides *which* widgets to
show and *where*, and SwiftUI renders that layout deterministically. Personal /
internal tool for the user, run locally.

**Status:** planned. Next = v0 spike (M0).
**Inference path (decided):** `claude -p` headless on the Max subscription.
**Design:** adopts the house design system (`kb/design-systems/atlasautomates`),
dark mode, pink accent.

---

## 1. Core idea — probabilistic layout, deterministic render

The split mirrors the Skills architecture (probabilistic decision + deterministic
execution):

```
Supabase (leads) ──► Swift fetches + summarizes the field catalog
                       │  (field names, types, counts, tiny sample — NOT raw PII)
                       ▼
   LLM reasoning step  │  claude -p  +  dashboard-layout skill
   "given these fields │  ───────────────────────────────────►  layout spec (JSON)
    and this viewport, │
    return a layout"   │  { breakpoints, cols, rowHeight, widgets:[{id,type,layout}] }
                       ▼
   Swift validates the spec (Codable + invariants)
       │  └─ on failure → deterministic DEFAULT layout (never blanks)
       ▼
   WidgetGrid renders the fixed widget library, binding real Supabase rows
```

The unreliable part (layout reasoning) is small and fully validated. Rendering and
data are 100% deterministic. The LLM never sees raw PII — only a field catalog +
optional aggregates (see §6, §8).

---

## 2. What we adopt from `builds/dashboard-template`

That template (React/Vite) already implements this exact pattern. We **port its
contract to SwiftUI** rather than reinventing it. Adopted wholesale:

| From the template | What we keep | SwiftUI port |
|---|---|---|
| `layout.json` | Responsive layout spec: `breakpoints`, `cols` per breakpoint, `rowHeight`, `widgets[]` each with per-breakpoint `{x,y,w,h}` | `LayoutSpec` Codable model; this is exactly what `claude -p` emits |
| `dashboard.json` | Theme/title/accent separated from layout | `ThemeConfig` (defaults from design system) |
| `widgets/*.json` | Per-widget data, `type`-discriminated (`kpi`, `chart`, `table`, `status-board`) | `WidgetData` enum + Codable; produced from Supabase rows |
| `widget-registry.js` | `type` → (display, config) map | `WidgetRegistry`: `WidgetType` → `@ViewBuilder` SwiftUI view |
| `data-loader.js` | cache-first load + persisted overlay | `LayoutCache` / `DataStore` (App Support dir + in-memory) |
| `WidgetGrid` / `WidgetWrapper` | grid placement from integer `(x,y,w,h)` | `WidgetGrid` view (see §5 for v0 simplification) |

**Key insight:** the template's `layout.json` *is* the layout-spec schema. The only
change for the native app is that **`claude -p` generates it at runtime** instead of
it being a static file, and **widget data comes from Supabase** instead of static
JSON. The contract is unchanged → the template's widget JSON shapes become our
target output schema.

The four registered widget types (`kpi`, `chart`, `table`, `status-board`) are the
v0 widget library.

---

## 3. The layout-spec contract (renderer input)

Verbatim shape from the template, lead-adapted — what `WidgetGrid` renders.

> **Note (M2 refinement):** the LLM no longer emits this directly. In M2 the model
> emits the smaller, enum-constrained **layout plan** (§6.1) and a deterministic Swift
> **`Packer`** expands it into the `LayoutSpec` below. So this remains the renderer's
> contract; the geometry (`x,y,w,h`) is machine-generated, never model-generated. In
> M1 this spec is produced by `DashboardBuilder`'s fixed layout.

```jsonc
{
  "breakpoints": { "lg": 1200, "md": 996, "sm": 768 },
  "cols":        { "lg": 12,   "md": 10,  "sm": 6 },
  "rowHeight": 80,
  "widgets": [
    {
      "id": "lead-count",
      "type": "kpi",                       // must be a registered WidgetType
      "binding": { "source": "leads", "agg": "count" },
      "layouts": {
        "lg": { "x": 0, "y": 0, "w": 3, "h": 2 },
        "md": { "x": 0, "y": 0, "w": 5, "h": 2 },
        "sm": { "x": 0, "y": 0, "w": 3, "h": 2 }
      }
    }
    // ... more widgets
  ]
}
```

**Widget-data shapes** (target output of the data layer, per the template):

```jsonc
// kpi
{ "type": "kpi", "title": "Enriched Leads", "value": 320, "format": "number",
  "previousValue": 280, "trend": "up", "trendLabel": "+14%", "sparkline": [..] }

// table
{ "type": "table", "title": "Recent Leads",
  "columns": [ { "key": "company", "label": "Company", "sortable": true },
               { "key": "sentiment", "label": "Sentiment", "variant": "badge" } ],
  "rows": [ { "company": "...", "sentiment": "positive" } ],
  "config": { "defaultSort": { "key": "created_at", "direction": "desc" } } }

// chart  → time series / category buckets (leads per campaign, per week)
// status-board → grouped counts by a categorical field (e.g. campaign stage)
```

---

## 4. Design system adoption

Translate `kb/design-systems/atlasautomates/tokens.css` → `DesignTokens.swift`.
**Dark mode default, accent pink `#dd7bbb`** (matches the template's `dashboard.json`).

| Token group | Source vars | Swift |
|---|---|---|
| Backgrounds | `--bg-root #050508`, `--bg-surface #0a0a10`, `--bg-elevated #101010` | `Color.bgRoot/.bgSurface/.bgElevated` |
| Text | `--text-primary #f0f0f5`, `--text-secondary #c0c0d8`, `--text-muted #6a6a88` | `Color.textPrimary/...` |
| Borders | `--border-default #1a1a2a`, `--border-hover #2a2a4a` | `Color.borderDefault/...` |
| Accent | `--accent #dd7bbb` (+ `accent-bg`, `accent-border`) | `Color.accentPink` |
| Status badges | green/purple/blue/orange/red bg+text pairs | `StatusStyle` enum (bg+fg) |
| Spacing | 8px grid `--space-1..12` | `Space` enum (4,8,12,16,24,32,40,64,96) |
| Radius | `--radius-xs..2xl`, `pill` | `Radius` enum |
| Type — data | `--font-mono` (SF Mono) | `Font.dataMono` — KPI numbers, tables |
| Type — chrome | `--font-sans` (→ SF Pro / system) | `Font.uiSans` |
| Type — display | `--font-display` (Playfair Display) | `Font.display` — bundled font, **optional in v0** (system serif fallback) |
| Motion | `--duration-*`, `--ease-smooth` | `Animation` presets |

Card surface convention: `bg-surface` fill, `border-default` 1px, `radius-lg`,
`shadow-layer-2`. SF Mono for all numeric/data values; system sans for labels/chrome.

---

## 5. Grid renderer

The template uses a 12-col `react-grid-layout` with `rowHeight: 80` and free
`(x,y,w,h)` placement. SwiftUI port:

- **v0:** honor `w`/`h` spans in a column grid (place in reading order, span columns
  by `w`, height = `h * rowHeight`). Simple, covers most layouts.
- **v1:** honor absolute `(x,y)` placement (true free grid) via a custom `Layout`.
- Breakpoint chosen by **window width** (Mac windows resize freely) → pick `lg/md/sm`
  bucket, re-pick on resize. No layout regeneration on resize (the spec carries all
  three breakpoints, exactly like the template).

---

## 6. Inference layer — M2 adaptive layout (Haiku, cache-gated)

**Decided 2026-06-23.** Model = **Haiku 4.5** (cheapest; the task is constrained
structured output, not open reasoning). Cadence = regenerate on open / refresh /
hourly, **all gated by an "if-changed" check** — never on a timer alone.

### 6.1 The accuracy move: LLM *plans*, Swift *places*

Do **not** have Haiku emit grid geometry (`x,y,w,h`) — small models produce overlaps
and out-of-bounds rects, and geometry is the easiest thing to get wrong. Instead the
LLM emits a **constrained layout plan** (which widgets, emphasis, order) and a
**deterministic Swift packer** turns that into the valid responsive `LayoutSpec` of §3.
This is the single biggest accuracy lever: Haiku makes only *semantic* choices (pick
from enums), and it is structurally impossible for it to emit a broken grid.

**LLM output — the layout plan (small, enum-constrained):**
```jsonc
{ "widgets": [
    { "type": "kpi",          "bind": "total-leads", "size": "small",  "priority": 1 },
    { "type": "status-board", "bind": "by-source",   "size": "medium", "priority": 2 },
    { "type": "chart",        "bind": "added-weekly", "size": "large",  "priority": 3 },
    { "type": "table",        "bind": "recent-leads", "size": "full",   "priority": 4 }
] }
```
- `type` ∈ registered `WidgetType`; `bind` ∈ a **fixed catalog of data series the
  builder can produce** (total-leads, by-source, by-industry, added-weekly,
  by-tier, sentiment-mix, recent-leads, …); `size` ∈ `{small, medium, large, full}`;
  `priority` orders placement. Max ~6 widgets.
- **`Packer.pack(plan, viewport) -> LayoutSpec`** (new, pure, deterministic): maps
  size→column span per breakpoint, bin-packs by priority into the 12/10/6-col grids,
  emits non-overlapping rects for lg/md/sm. Reuses `WidgetGrid.sanitize` as a backstop.
- `DashboardBuilder` already produces the widget *data* for each `bind`; M2 only swaps
  the **fixed layout** for a packed plan. Unbound/unknown `bind`s are dropped.

### 6.2 `dashboard-layout` skill + `LayoutEngine`

- **`dashboard-layout` skill** (`.claude/skills/dashboard-layout/`) holds the prompt:
  the widget-type + bind + size-class catalogs, the rules, and **2–3 few-shot
  (profile → plan) examples** (few-shot is a major accuracy lever for Haiku).
- **`LayoutEngine`** spawns: `claude -p "<profile+viewport>" --model claude-haiku-4-5
  --output-format json --system-prompt "<layout rules>" --max-turns 1` (no tools),
  run from a **temp cwd, NOT the repo**, so Arcane's large `CLAUDE.md` / all skills do
  **not** load — keeps Haiku's context tiny and undistracted (accuracy + cost). Parse
  the JSON envelope → `.result` → decode the plan.

### 6.3 Haiku accuracy checklist (apply all)

1. **Constrained plan, not geometry** (§6.1) — can't emit a broken grid.
2. **Slim, dedicated system prompt** — enumerate valid `type`/`bind`/`size` values,
   the max-widget cap, and "output ONLY the JSON plan, no prose." Run outside the repo
   so the big project context doesn't crowd the window.
3. **Few-shot examples** (2–3) of profile → plan in the skill.
4. **Single-shot, no tools** (`--max-turns 1`) — nothing to wander into.
5. **Validate + ONE repair retry** — decode the plan against the enums; on failure,
   re-prompt once with the parse error; if it still fails → **fail-closed to
   `DefaultLayout.plan`**. Caps cost at ≤2 calls and never blanks.
6. **Determinism** — low effort; the constrained schema leaves little to vary.

**⛔ Step-C MANDATORY guards (from the step-B review — do not skip):**
- **Validate binds before caching.** A plan may only be saved if every `bind` is in the
  known data-series set AND `widgets` is non-empty; otherwise use `DefaultLayout.plan`
  and DON'T save. Do this *inside* `LayoutResolver` before `LayoutCache.save`, or a
  hallucinated bind gets persisted and replayed every launch (cache poisoning — reliability
  rated this HIGH the moment the LLM lands). Renderer already drops data-less widgets, but
  enforce it at the gate, not just visually.
- **Generation never throws.** The `claude -p` wrapper must catch timeout / non-zero exit /
  empty / fence-wrapped / non-JSON output (per `learnings.md` JSON-fence handling) and
  return `DefaultLayout.plan` — never throw into `load()`'s catch (would degrade to
  `.failed`/`.stale`), never save a bad plan.
- **Resolver goes async.** `generate` is currently `(DataProfile) -> LayoutPlan` (sync);
  the Haiku call is async → change to `async` and thread it through `load()`.
- Add a selftest asserting a resolved plan's binds all resolve to data.

### 6.4 Cache-gating (the cost control)

- **Cache key = the data profile only** (revised at step B — viewport dropped). The plan
  is viewport-agnostic; `Packer` makes it responsive across lg/md/sm from one plan, so
  there's no reason to cache per-viewport (it would just triple LLM calls). `DataProfile`
  (`Models/DataProfile.swift`) is a coarse signal vector — for each candidate `bind`:
  present? how strong? (distinct-category count, % non-null, row-volume bucketed, coarse
  on purpose so the key changes slowly). Key = deterministic sorted string (NOT Swift's
  randomized `hashValue` — that would defeat the cache across launches). This is what
  makes the layout *adaptive* (a campaign rich in sentiment shows a sentiment widget; a
  sparse one doesn't) while staying cheap. *(Future: reintroduce viewport in the key only
  if we want viewport-specific widget selection.)*
- **Every trigger — open, manual Refresh, hourly tick — recomputes the key and only
  calls Haiku if it changed** ("if-changed" gate; per user 2026-06-23 this includes
  Refresh). Cold start (no cached plan) generates once. Refresh always re-fetches data
  but only re-generates the layout when the profile shifts. Cached plan persists to
  App Support; the packed `LayoutSpec` is recomputed deterministically from the plan.
- **No PII to the model:** the profile carries series names + coarse stats only; the
  model picks widgets, Swift binds real rows locally.

### 6.5 Cost

Haiku 4.5 ($1/$5 per MTok), slim prompt (~3K in / ~1K out ≈ **$0.008/call**),
cache-gated → calls only on profile change (a handful/week). **Est. < $1/mo** against
the $200 Agent SDK credit. Worst case (force every hour, ungated) ≈ $8/mo — avoided by
the if-changed gate.

> ⚠️ **Agent SDK credit:** `claude -p` is metered against the $200/mo Max credit (no
> rollover), API overflow beyond. This design keeps usage negligible — a deliberate,
> cheap choice.

---

## 7. Project structure (SwiftUI macOS app)

```
builds/lead-dashboard/
  LeadDashboard.xcodeproj            (or SwiftPM — decide at M0)
  Sources/
    App/            LeadDashboardApp.swift, RootView.swift
    Theme/          DesignTokens.swift, Components.swift (Card, Badge, …)
    Models/         LayoutSpec.swift, WidgetData.swift, ThemeConfig.swift
    Data/
      SupabaseClient.swift           (read-only; key in Keychain)        [M1 ✓]
      LeadsRepository.swift, DashboardBuilder.swift                       [M1 ✓]
      LayoutEngine.swift             (claude -p Haiku invocation + parse) [M2]
      LayoutPlan.swift               (enum-constrained plan model, §6.1)  [M2]
      Packer.swift                   (plan → LayoutSpec, deterministic)   [M2]
      DataProfile.swift              (coarse signal vector for cache key) [M2]
      LayoutCache.swift              (key = profile+viewport, App Support)[M2]
    Widgets/        WidgetRegistry.swift, KpiCard.swift, DataTable.swift,
                    ChartWidget.swift, StatusBoard.swift
    Grid/           WidgetGrid.swift, WidgetWrapper.swift
    Shell/          DashboardShell.swift, Toolbar.swift
```

Build/run via XcodeBuildMCP (already in `.mcp.json`).

---

## 8. Supabase integration

- **Read-only.** `leads` table primary; `lead_enrichment` (lead_tier,
  enrichment_status, web_research_json), `replies` (sentiment, intent), and
  `lead_interactions` (timeline) for richer widgets. Schema grounded in
  `.claude/shared/supabase_client.py` (`map_lead_to_supabase` is the column contract);
  live-DB MCP timed out, but the shared client is authoritative.
- **Client: dependency-free PostgREST over URLSession** (decided at M1, revised from
  `supabase-swift`). We only read (SELECT); avoids a remote SPM dependency and its
  build-resolution risk on flaky networks. Revisit `supabase-swift` only if realtime/
  auth/storage is ever needed.
- **API key in macOS Keychain** — never hardcoded, no env-default fallback; app fails
  closed (setup prompt) if absent. Mirrors the Python infra's local service-key use;
  if ever distributed, switch to anon key + an RLS read policy.
- Swift aggregates rows client-side into the §3 widget-data shapes.
- **No PII in logs** or in the `claude -p` prompt (field catalog + aggregates only).
- Project: `YOUR-PROJECT-REF` → `https://YOUR-PROJECT-REF.supabase.co/rest/v1`
  (authoritative source = `.env SUPABASE_URL`). NOTE: `.mcp.json` carries a **stale
  ref** `fcgmdeeckzlbwiymorvy` (DNS NXDOMAIN) — the likely cause of the Supabase MCP
  timeouts; fixing that ref should restore the MCP too.

---

## 9. v0 milestones

- **M0 ✓ — Renderer + design system.** Hardcoded layout renders all 4 widget types
  with mock data. Proves the grid + house look.
- **M1 ✓ — Real data.** Supabase fetch (anon key) → bind real leads → widget data;
  `Loadable` state model; chart polish + auto-hiding titlebar.
- **M2 — Adaptive layout (Haiku, cache-gated).** Per §6: `dashboard-layout` skill +
  `LayoutEngine` (`claude -p --model claude-haiku-4-5`, run outside the repo, single-
  shot) emits an enum-constrained **plan**; `Packer` deterministically expands it to a
  `LayoutSpec`; `DataProfile`-keyed cache gates every trigger (open/refresh/hourly) on
  **if-changed**; validate + 1 repair retry → fail-closed to the M1 fixed layout.
  Suggested sub-steps: (a) `LayoutPlan` + `Packer` + tests (no LLM); (b) `DataProfile`
  + cache + if-changed gate; (c) `LayoutEngine` + skill + wire the Refresh/hourly path.
- **M3 — Responsive + controls.** Window-resize breakpoint switching (partly in M1),
  campaign/view filter, expose the "Re-layout" button (force-regenerate, bypass gate).

Each milestone: build & verify it renders before moving on.

---

## 10. Review & security

- **New skill + new app** → full **baseline review team** per CLAUDE.md
  (code-reviewer, qa, reliability-reviewer, security-reviewer). `responsiveness-reviewer`
  is web-viewport-scoped → N/A for a native app (window-resize handled in M3 + QA).
- Phase-2 `delta-reviewer` after fixes (criteria will trigger: new app, >20 LOC).
- Security: read-only Keychain DB key; fail-closed layout; no PII in logs/prompts;
  `claude -p` timeout + cached-layout fallback if the CLI is unavailable.

---

## 11. Decisions log

1. Default view = all leads; campaign filter deferred to M3. *(open — M3)*
2. ~~Display font~~ → **resolved (M0): system serif fallback**; bundle Playfair later if wanted.
3. ~~Grid placement~~ → **resolved (M0): absolute `(x,y,w,h)` placement** per breakpoint (the planned "v1" landed early).
4. ~~`supabase-swift` via SPM~~ → **resolved (M1): dependency-free PostgREST over URLSession** (read-only). See §8.
5. ~~Service key vs anon+RLS~~ → **resolved (2026-06-23): anon key** (read-only, RLS-subject). See §8 + memory `reference_supabase_access`.
6. ~~M2 model / cadence~~ → **resolved (2026-06-23): Haiku 4.5, cache-gated, if-changed on every trigger incl. Refresh.** See §6.
7. *(open — M2)* Whether the "Re-layout" button force-regenerates (bypass the gate) — leaning yes, as the one manual override.
