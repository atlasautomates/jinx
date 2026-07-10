# Lead Dashboard

Native macOS (SwiftUI) dashboard for Supabase lead data — three tabs (Leads,
Campaigns, Pipeline), each a deterministic fetch → compose → build over read-only
anon queries. See `BUILD_PLAN.md` for history.

**Status:** live on Supabase; the M2 adaptive (Haiku) layout was removed in the
P1 renovation (2026-07) in favor of fixed deterministic layouts on every tab.

## Run

```sh
cd builds/lead-dashboard
swift run                 # launches the app window
```

Resize the window to see the responsive breakpoints (`lg` ≥1200, `md` ≥996, `sm`
below) switch — the indicator pill in the toolbar shows the active one.

## Verify (headless)

```sh
swift build
./.build/debug/LeadDashboard --selftest    # decodes the mock contract, prints PASS/FAIL
```

## What's here (M0)

- `Theme/` — `DesignTokens.swift` (atlasautomates tokens → Swift: dark mode, pink
  accent, SF Mono for data, 8px grid), `Components.swift` (Card, Badge, SectionLabel,
  Sparkline).
- `Models/` — the layout-spec + widget-data Codable contract (`claude -p`'s M2 target).
- `Widgets/` — the four widget views (`kpi`, `chart`, `table`, `status-board`) + the
  `WidgetWrapper` registry that dispatches on type.
- `Grid/WidgetGrid.swift` — absolute `(x,y,w,h)` placement per breakpoint.
- `Shell/` — toolbar + scrollable grid.
- `Mock/MockData.swift` — hardcoded lead-themed layout + widget data.

## Next (M1)

Replace `MockData` with a Supabase read (read-only key in Keychain) → bind real leads
into the same widget-data shapes. Schema verified against the live DB at M1.
