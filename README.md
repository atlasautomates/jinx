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

Offline dev mode (no Keychain, no network — the Leads tab only):

```sh
swift run CECDashboard --fixture
```

`--fixture` boots the real window over a synthetic lead book, so live-layout and
interaction questions (where the list starts, whether a column scrolls, how a
filter feels) can be answered without credentials. The still harness cannot answer
them: `ImageRenderer` can't rasterize a `ScrollView`, so every `--screenshot` goes
through the `staticRender` substitute path.

## Verify (headless)

```sh
swift build
./.build/debug/CECDashboard --selftest         # pure seams + preview render checks
./.build/debug/CECDashboard --check-supabase   # live reads incl. lane/reply probes
./.build/debug/CECDashboard --screenshot list  # registered preview stills
./xcode/icon/gen-icons.sh                      # regenerate the app icon
```

The app icon is a VIEW (`Views/AppIconArt.swift`) rendered through the preview
harness, not a drawing script — that keeps it on the same OKLCH tokens as the UI
instead of a forked set of hex values. Re-run `gen-icons.sh` after changing it or
any colour token it reads.

## What's here (M0)

- `Theme/` — `ABTokens.swift` defines `enum DesignTokens`, the OKLCH channel tokens
  the Leads tab and the app icon both read (teal identity hue 192, pink reply role
  hue 350, near-black world). `DesignTokens.swift` defines the older `enum Palette`
  (hex, pink accent) still used by the Campaigns/Pipeline widgets.
  `Components.swift` (Card, Badge, SectionLabel, Sparkline).
- `Models/` — the layout-spec + widget-data Codable contract (`claude -p`'s M2 target).
- `Widgets/` — the four widget views (`kpi`, `chart`, `table`, `status-board`) + the
  `WidgetWrapper` registry that dispatches on type.
- `Grid/WidgetGrid.swift` — absolute `(x,y,w,h)` placement per breakpoint.
- `Shell/` — toolbar + scrollable grid.
- `Mock/MockData.swift` — hardcoded lead-themed layout + widget data.

## Next (M1)

Replace `MockData` with a Supabase read (read-only key in Keychain) → bind real leads
into the same widget-data shapes. Schema verified against the live DB at M1.
