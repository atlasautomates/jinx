# Jinx

Jinx is the lead dashboard behind Atlas Automates' outreach pipeline: a native
macOS (SwiftUI) app over a Postgres/Supabase lead book. It shows funnel KPIs,
trends, breakdowns, search, filters, and a per-lead dossier with the full
interaction timeline the backend records.

**Read-only showcase.** This repository is published as a record of the work,
June to November 2026. It is extracted from a private monorepo, so some docs
refer to paths and plans that aren't included here. Contributions, issues and
pull requests are not accepted. No license is granted.

Try it without any credentials: `swift run CECDashboard --demo` boots the
real window over a synthetic book of fictional solar companies.

---

# Lead Dashboard

Native macOS (SwiftUI) dashboard for Supabase lead data — ONE surface (Leads),
a deterministic fetch → compose → derive over read-only queries against the
`v_cec_*` reader-boundary views (four consumed: leads, sent_events,
lead_interactions, lead_profile; the campaigns pair awaits the future Campaigns
app). Credentials are TWO Keychain items — `supabase_api_key` (the
`arcane_read_cec` reader JWT, rides the Authorization bearer; SELECT on exactly
the v_cec_* views) and `supabase_anon_key` (the project anon key, rides the
`apikey` gateway header). Seed both per install-mac.sh's CREDENTIAL ORDER note. See `BUILD_PLAN.md` for history.

**Status:** live on Supabase. The Campaigns and Pipeline tabs were DEPRECATED and
deleted 2026-08-16 (leads-domain-split 7.2, Adrian's ruling): Pipeline was unused,
Campaigns held write access and may return as its own app. Their sources live in
git history (`git log -- Sources/CECDashboard/Views/ABCampaigns`).

## Run

```sh
cd builds/lead-dashboard
swift run                 # launches the app window
```

Offline dev mode (no Keychain, no network):

```sh
swift run CECDashboard --fixture
```

`--fixture` boots the real window over a synthetic lead book, so live-layout and
interaction questions (where the list starts, whether a column scrolls, how a
filter feels) can be answered without credentials. The still harness cannot answer
them: `ImageRenderer` can't rasterize a `ScrollView`, so every `--screenshot` goes
through the `staticRender` substitute path.

Showcase mode, for portfolio screenshots (#113):

```sh
swift run CECDashboard --demo
```

`--demo` boots the real window over `Mock/DemoBook.swift`: 160 fictional solar
installers, most fields filled and some deliberately blank, with a dossier
and interaction timeline behind every row. Rows, search hits and pin chips open
the profile sheet offline. Pins persist in `Application Support/CECDashboard-demo/`,
never the real pin file. Contacts are provably fictional (`.example` domains,
555-01xx phones), and `--selftest` enforces that. Like `--fixture`, it is
DEBUG-only.

## Verify (headless)

```sh
swift build
./.build/debug/CECDashboard --selftest         # pure seams + preview render checks
./.build/debug/CECDashboard --check-supabase   # reader-boundary probes (every consumed view + credential expiry)
./.build/debug/CECDashboard --screenshot list  # registered preview stills
./xcode/icon/gen-icons.sh                      # regenerate the app icon
```

The app icon is a VIEW (`Views/AppIconArt.swift`) rendered through the preview
harness, not a drawing script — that keeps it on the same OKLCH tokens as the UI
instead of a forked set of hex values. Re-run `gen-icons.sh` after changing it or
any colour token it reads.

## What's here

- `Theme/` — `ABTokens.swift` defines `enum DesignTokens`, the OKLCH channel tokens
  the Leads surface and the app icon both read (teal identity hue 192, pink reply
  role hue 350, near-black world). `DesignTokens.swift` defines the older `enum
  Palette` (hex) still used by the profile sheet. `Components.swift` (Card, Badge,
  SectionLabel, Sparkline).
- `Models/` — `LeadRow` (the `v_cec_leads` decode incl. status axes), `LeadFilter`/
  `LeadFacets`/`LeadSnapshot` (the one-derivation filter layer), `DashboardInputs`,
  `ProfileRow` (the `v_cec_lead_profile` + interactions decodes).
- `Data/` — `SupabaseClient` (thin GET-only PostgREST client), `LeadsRepository`
  (keyset walks over `v_cec_leads` / `v_cec_sent_events` / `v_cec_lead_interactions`),
  `ProfileRepository`, `ProfileFacts`, `Keychain`, `PinsStore`.
- `Views/ABLeads/` — the re-skinned Leads surface (KPI hero, trends, breakdowns,
  filter bar, search, list). `Views/LeadProfileView.swift` — the dossier sheet.
- `App/` — view models, App Intents (Siri), `--query` CLI, `--selftest`,
  `--check-supabase`, the preview harness.
