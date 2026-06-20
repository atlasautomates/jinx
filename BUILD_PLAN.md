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

## 3. The layout-spec contract (LLM output target)

Verbatim shape from the template, lead-adapted. This is what the `dashboard-layout`
skill must emit and what Swift decodes:

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

## 6. Inference layer — `claude -p`

`LayoutEngine` spawns the Claude Code CLI headless:

```
claude -p "<request>" --output-format json     (cwd = repo, so the skill loads)
```

- **`dashboard-layout` skill** (`.claude/skills/dashboard-layout/`) holds the prompt
  logic: input = field catalog + viewport + widget-type catalog; output = a
  `LayoutSpec` JSON conforming to §3. Versioned, reusable, follows skill conventions.
- Swift parses the `--output-format json` envelope → `.result` → extracts/validates
  the layout JSON.
- **Fail-closed:** decode via Codable + check invariants (known `type`s, valid
  breakpoints, no NaN spans). On any failure → render a **deterministic default
  layout** (one KPI row + one leads table). The screen never blanks.
- **Caching:** key on `(sorted field-set + breakpoint-bucket)`. Persist to App
  Support. Regenerate only when the data *shape* changes or the user hits
  "Re-layout". A normal open does **zero** LLM calls → near-zero credit use.
- **No PII to the model:** the prompt carries field *names/types/counts* and at most
  a tiny anonymized sample — the model picks widgets, Swift binds real rows locally.

> ⚠️ **Agent SDK credit:** `claude -p` runs on the Max sub but is metered against the
> monthly Agent SDK credit ($200/mo, no rollover), overflowing to metered API beyond
> that. With layout-spec caching, real usage is a handful of small calls — credit
> easily covers it. Flagged so it stays a deliberate choice.

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
      SupabaseClient.swift           (read-only; key in Keychain)
      LayoutEngine.swift             (claude -p invocation + validation)
      LayoutCache.swift, DataStore.swift
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

- **M0 — Renderer + design system.** Xcode scaffold, `DesignTokens.swift`, a
  *hardcoded* `layout.json` renders all 4 widget types with mock data. Proves the
  grid + house look. *(No Supabase, no LLM yet.)*
- **M1 — Real data.** Supabase fetch → bind real leads into widget data.
- **M2 — Adaptive layout.** `dashboard-layout` skill + `LayoutEngine` (`claude -p`)
  + schema validation + fail-closed default + caching.
- **M3 — Responsive + controls.** Window-resize breakpoint switching, "Re-layout"
  button, campaign/view filter.

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

## 11. Open decisions (recommended defaults in **bold**)

1. **Default view = all enriched leads**, with a campaign filter in M3. (vs. per-campaign on launch)
2. **System serif fallback for display font in v0**; bundle Playfair Display later. (vs. bundle now)
3. **v0 grid honors `w`/`h` spans only**; absolute `(x,y)` free-placement in v1. (vs. full grid at v0)
4. ~~`supabase-swift` via SPM~~ → **resolved at M1: dependency-free PostgREST over
   URLSession** (read-only; no remote dependency to resolve). See §8.

None block M0 (renderer + design system, all mock data).
