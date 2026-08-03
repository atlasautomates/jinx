import SwiftUI

// ARM-B re-skinned Leads tab. Neon-teal view identity + pink reward role, on a
// near-black world. Renders the frozen A/B fixture, no network. Hierarchy top to
// bottom: (1) KPI ratios, (2) trends, (3) breakdowns, (4) recent list.

struct ABLeadsView: View {
    var data: ABLeadsData = .ab
    /// Interaction-demo variant: forces a pressed hero + hovered row/status for
    /// the `leads-detail` preview (states are invisible in a still otherwise).
    var interactionDemo: Bool = false
    /// Offscreen ImageRenderer can't capture ScrollView content — the harness
    /// sets this true to swap ScrollViews for clipped stacks. The running app
    /// leaves it false and stays genuinely scrollable (decision-log #16).
    var staticRender: Bool = false

    // Live-mode hooks. All default to nil/false, so the fixture/harness path
    // renders byte-identically to the frozen A/B artifact (nothing extra appears).
    /// Row tap → open the lead profile. Fired only for rows carrying a DB id.
    var onSelectLead: ((ABLeadsData.Lead) -> Void)? = nil
    /// Manual refresh affordance. When set, a refresh control appears in the header.
    var onRefresh: (() -> Void)? = nil
    /// True while a live refresh is in flight — spins/disables the refresh control.
    var isRefreshing: Bool = false
    /// When set, a slim "showing last data" banner rides above the content.
    var staleMessage: String? = nil
    /// When set, an unmissable banner marks the dev-only offline fixture mode.
    var fixtureNotice: String? = nil
    /// When the data on screen was loaded ("as of 14:32"). Nothing else on the tab
    /// states the numbers' age, and the poll loop is a plain sleep — a lid opened
    /// after a weekend otherwise reads as current.
    var loadedAt: Date? = nil
    /// Filter changes (live tab). nil = the bar is inert (fixture/harness path).
    var onFilterChange: ((LeadFilter) -> Void)? = nil
    /// Search box binding + actions. nil = no search box (fixture/harness path,
    /// unless `searchState` is set for a still).
    var searchQuery: Binding<String>? = nil
    var searchState: LeadSearchModel.SearchState = .idle
    var onSearchSubmit: (() -> Void)? = nil
    var onSearchClear: (() -> Void)? = nil

    /// True while search results own the list column.
    private var searching: Bool {
        switch searchState {
        case .idle: return false
        case .searching, .results, .failed: return true
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            DesignTokens.bgRoot.ignoresSafeArea()

            // One overhead light source for the whole world (bible §5) — a faint
            // teal wash at the top edge, receding downward.
            LinearGradient(colors: [DesignTokens.accent.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)

            content
                .padding(.horizontal, DesignTokens.space6)
                .padding(.vertical, DesignTokens.space5)
        }
        .background(DesignTokens.bgRoot)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var stack: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            if let fixtureNotice { ABFixtureBanner(message: fixtureNotice) }
            if let staleMessage { ABStaleBanner(message: staleMessage) }
            header
            ABFilterBar(data: data, searching: searching,
                        onChange: onFilterChange ?? { _ in })                 // lens
            ABKpiHeroRow(data: data, forcedPressedHero: interactionDemo)       // level 1
            ABTrendRow(data: data)                                            // level 2

            // VARIANT C: levels 3 + 4 share one band (Arm A layout). The lead list
            // flexes wide on the LEFT so it clears the fold; the breakdowns stack
            // COMPACTLY in a narrow right column.
            //
            // This band takes the REMAINING window height — the page itself does
            // not scroll. Each column owns its own bounded scroll view, which is
            // what keeps the list starting at its first row (see ABLeadRowsTable)
            // and keeps the hero figures on screen while a filter is being changed:
            // watching those numbers move IS the filter's feedback.
            HStack(alignment: .top, spacing: DesignTokens.space5) {
                listColumn                                                    // level 4
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ABBreakdownRowGroup(data: data,
                    staticRender: staticRender,
                    forcedHoverStatusLabel: interactionDemo ? "Replied" : nil) // level 3
                    .frame(width: 384)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Search results take over the list column while a search is on screen —
    /// two lists side by side would leave "which of these is the lead book?"
    /// unanswered.
    @ViewBuilder
    private var listColumn: some View {
        if searching {
            ABSearchResultsPanel(state: searchState, staticRender: staticRender,
                                 onSelect: onSelectLead,
                                 onClear: onSearchClear ?? {})
        } else {
            // effectiveFilter, NOT filter: this caption STATES what the rows are.
            // Reading the requested filter here titled the panel "Filtered leads ·
            // Deep lane" over the entire unfiltered book whenever a lane read failed
            // and the dimension was suppressed. The bar edits `filter`; every surface
            // that makes a claim about the rows reads `effectiveFilter`.
            ABRecentLeadsTable(leads: data.recentLeads,
                               matchingCount: data.matchingCount,
                               filterSummary: data.effectiveFilter.summary,
                               forcedHoverIndex: interactionDemo ? 1 : nil,
                               staticRender: staticRender,
                               onSelect: onSelectLead)
        }
    }

    @ViewBuilder
    private var content: some View {
        // No page-level ScrollView, in either mode: the tab is a fixed dashboard
        // whose one scrolling region is the list. (The harness additionally can't
        // capture ScrollView content at all, which `staticRender` handles inside
        // the columns.)
        stack
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignTokens.space4) {
            VStack(alignment: .leading, spacing: DesignTokens.space1) {
                Text("Leads")
                    .font(.adventor(DesignTokens.textXl, bold: true))
                    .foregroundStyle(DesignTokens.textPrimary)
                Rectangle().fill(DesignTokens.accent)
                    .frame(width: 34, height: 2)   // flat teal rule (glow reserved for hero)
            }
            if let searchQuery {
                ABSearchField(query: searchQuery,
                              isSearching: searchState.isSearching,
                              hasResults: searching,
                              onSubmit: onSearchSubmit ?? {},
                              onClear: onSearchClear ?? {})
            }
            Spacer(minLength: DesignTokens.space4)
            HStack(spacing: DesignTokens.space4) {
                if !data.degradedReads.isEmpty { ABDegradedChip(reads: data.degradedReads) }
                summaryStat(value: data.totals.scraped, label: "scraped", color: DesignTokens.textSecondary)
                summaryStat(value: data.totals.emailed, label: "emailed", color: DesignTokens.accent)
                summaryStat(value: data.totals.replies, label: "replies", color: DesignTokens.accentPink)
                if let loadedAt { ABLoadedStamp(at: loadedAt) }
                // Live only: nil in the fixture/harness path → header stays frozen.
                if let onRefresh {
                    ABRefreshButton(isRefreshing: isRefreshing, action: onRefresh)
                }
            }
        }
    }

    private func summaryStat(value: Int, label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space1) {
            Text(value, format: .number)
                .font(.abMono(DesignTokens.textBase, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.adventor(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textMuted)
        }
    }
}

/// "as of HH:mm" beside the header stats. The tab polls on a plain sleep timer,
/// which does not advance across system sleep — without a stamp, numbers loaded
/// before a weekend read as current.
private struct ABLoadedStamp: View {
    let at: Date

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Text("as of \(Self.formatter.string(from: at))")
            .font(.abMono(DesignTokens.textXs))
            .foregroundStyle(DesignTokens.textGhost)
            .help("When this data was loaded. Refresh to update.")
    }
}

/// Header refresh affordance (live tab only). Hover lifts + brightens (bible §6);
/// while a refresh is in flight it spins and disables. The spin is state-driven
/// feedback, not idle motion — it stops the moment the load lands.
private struct ABRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? DesignTokens.accentStrong : DesignTokens.accent)
                .padding(DesignTokens.space2)
                .background(Circle().fill(hovering ? DesignTokens.accentBg : Color.clear))
                .overlay(Circle().strokeBorder(
                    hovering ? DesignTokens.accentBorder : DesignTokens.borderDefault, lineWidth: 1))
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? ABMotion.spin : ABMotion.fast, value: isRefreshing)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .scaleEffect(hovering && !isRefreshing ? 1.06 : 1.0)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .help("Refresh leads")
    }
}
