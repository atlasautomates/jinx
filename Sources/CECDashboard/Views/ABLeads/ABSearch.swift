import SwiftUI

// Lead search: a box in the tab header, and the hit list it swaps in for the
// recent-leads panel. Enter runs a server query over the whole book; a hit opens
// the same profile sheet as any other row on any other tab.

struct ABSearchField: View {
    @Binding var query: String
    let isSearching: Bool
    /// True once a search has produced something on screen — enables the clear
    /// affordance even if the box has been edited since.
    let hasResults: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: isSearching ? "hourglass" : "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focused ? DesignTokens.accent : DesignTokens.textMuted)

            // A live TextField is AppKit-backed, so the still-render path draws the
            // typed value as plain text instead (same chrome, same metrics) — the
            // harness only needs to show the box's STATE, and an ungated field
            // would paint a yellow placeholder over the header.
            if isStaticRender {
                Text(query.isEmpty ? "Search leads" : query)
                    .font(.adventor(DesignTokens.textSm))
                    .foregroundStyle(query.isEmpty ? DesignTokens.textGhost : DesignTokens.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search company or name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.adventor(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .frame(maxWidth: .infinity)
            }

            if !query.isEmpty || hasResults {
                ABClearGlyph(action: onClear)
            }
        }
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.controlPaddingY)
        .background(Capsule().fill(DesignTokens.bgSurface))
        .overlay(Capsule().strokeBorder(
            focused ? DesignTokens.accentBorder : DesignTokens.borderDefault, lineWidth: 1))
        .frame(width: DesignTokens.searchFieldWidth)
        .animation(ABMotion.fast, value: focused)
        // ⌘F is published as a focused value so the app's Find command can reach it
        // (see CECDashboardApp.commands). A hidden Button carrying the shortcut
        // would collide with the system Edit ▸ Find item — which resolves first —
        // and would also fire from the other tabs, moving focus into a TextField
        // nobody can see.
        .focusedSceneValue(\.leadSearchFocus, LeadSearchFocus { focused = true })
    }
}

/// The search box's clear affordance. A `.plain` glyph with a constant colour is
/// indistinguishable from decoration; this one acknowledges the pointer.
private struct ABClearGlyph: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(hovering ? DesignTokens.textSecondary : DesignTokens.textGhost)
                .scaleEffect(hovering ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .help("Clear search")
        .accessibilityLabel("Clear search")
    }
}

/// Focus hook for the app-level Find command.
struct LeadSearchFocus {
    let focus: () -> Void
    init(_ focus: @escaping () -> Void) { self.focus = focus }
}

private struct LeadSearchFocusKey: FocusedValueKey {
    typealias Value = LeadSearchFocus
}

extension FocusedValues {
    var leadSearchFocus: LeadSearchFocus? {
        get { self[LeadSearchFocusKey.self] }
        set { self[LeadSearchFocusKey.self] = newValue }
    }
}

/// Search on its own, above the full-tab error state. The snapshot read failing
/// says nothing about whether a lead can be looked up — and that is precisely when
/// someone wants to.
struct ABSearchOnlyHeader: View {
    @Binding var query: String
    let state: LeadSearchModel.SearchState
    let onSubmit: () -> Void
    let onClear: () -> Void
    var onSelectLead: ((ABLeadsData.Lead) -> Void)? = nil

    private var showingResults: Bool {
        if case .idle = state { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            HStack(alignment: .center, spacing: DesignTokens.space4) {
                Text("Leads")
                    .font(.adventor(DesignTokens.textXl, bold: true))
                    .foregroundStyle(DesignTokens.textPrimary)
                ABSearchField(query: $query,
                              isSearching: state.isSearching,
                              hasResults: showingResults,
                              onSubmit: onSubmit,
                              onClear: onClear)
                Spacer(minLength: 0)
            }
            if showingResults {
                ABSearchResultsPanel(state: state, onSelect: onSelectLead, onClear: onClear)
                    .frame(maxHeight: 420)
            }
        }
        .padding(.horizontal, DesignTokens.space6)
        .padding(.top, DesignTokens.space5)
        .background(DesignTokens.bgRoot)
    }
}

/// The hit list. Replaces the recent-leads panel while a search is on screen, so
/// the tab never shows two competing lists — and states plainly that it is showing
/// search results over the WHOLE book, not the filtered view underneath.
struct ABSearchResultsPanel: View {
    let state: LeadSearchModel.SearchState
    var staticRender: Bool = false
    /// The lens the hits are narrowed by — nil when nothing is filtered.
    var scopeSummary: String? = nil
    /// True while the user has asked to see hits from outside the filter.
    var ignoringFilters: Bool = false
    /// Toggle the filter on the results. nil = no control (harness/fixture path).
    var onToggleFilters: ((Bool) -> Void)? = nil
    var onSelect: ((ABLeadsData.Lead) -> Void)? = nil
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            header
            content
        }
        .padding(.vertical, DesignTokens.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Focus is a depth event: this panel answers the question the user just
        // asked, so it takes the accent edge rather than wearing the same chrome as
        // the ambient panels it replaced.
        .abSurface(.surface, radius: DesignTokens.radiusLg,
                   accentBorder: DesignTokens.accentBorder)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.space2) {
            ABSectionLabel("Search results")
            if case .results(_, let hits, _) = state {
                Text("(\(hits.count)\(hits.count >= LeadsRepository.searchResultLimit ? "+" : ""))")
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
            }
            if let term = state.term {
                Text("“\(term)”")
                    .font(.adventor(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            // The lens the hits obey, stated where the hits are. The query itself
            // always covers the whole book — only the RESULTS are narrowed — so
            // anything the filter removed is counted and offered below rather than
            // silently dropped.
            if let scopeSummary, !ignoringFilters {
                Text("within \(scopeSummary)")
                    .font(.adventor(DesignTokens.textXs, bold: true))
                    .foregroundStyle(DesignTokens.accent)
                    .lineLimit(1)
            } else if scopeSummary != nil {
                Text("whole lead book · filter ignored")
                    .font(.adventor(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textMuted)
            }
            Spacer()
            hiddenNotice
            ABBackToLeadsButton(action: onClear)
        }
        .padding(.horizontal, DesignTokens.space3)
    }

    /// "+N outside this filter" — the counted, clickable escape hatch. A hit the
    /// lens removes must never be indistinguishable from a lead that isn't there.
    @ViewBuilder
    private var hiddenNotice: some View {
        if case .results(_, _, let hidden) = state, let onToggleFilters {
            if hidden > 0 && !ignoringFilters {
                ABInlineLink(text: "+\(hidden) outside this filter",
                             icon: "plus.magnifyingglass") { onToggleFilters(true) }
            } else if ignoringFilters {
                ABInlineLink(text: "apply filter", icon: "line.3.horizontal.decrease") {
                    onToggleFilters(false)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()
        case .searching(let term):
            ABMessageRow(icon: "hourglass", text: "Searching for “\(term)”…",
                         tone: .muted, spinning: true, centered: true)
        case .failed(_, let message):
            // A failed search must never look like "no such lead".
            ABMessageRow(icon: "exclamationmark.triangle", text: message,
                         tone: .warn, centered: true)
        case .results(let term, let hits, let hidden):
            if hits.isEmpty {
                // An empty result under an active filter is NOT "no such lead" —
                // say which it is, and offer the wider search.
                ABMessageRow(icon: "questionmark.circle",
                             text: hidden > 0
                                 ? "No lead matches “\(term)” within this filter — \(hidden) match outside it."
                                 : "No lead matches “\(term)”.",
                             tone: .muted, centered: true)
            } else {
                ABLeadRowsTable(leads: hits, staticRender: staticRender, onSelect: onSelect)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// Small inline action inside a panel header (teal, hover-lit, real hit area).
private struct ABInlineLink: View {
    let text: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.space1) {
                Image(systemName: icon).font(.system(size: 8, weight: .bold))
                Text(text).font(.adventor(DesignTokens.textXs, bold: true))
            }
            .foregroundStyle(hovering ? DesignTokens.accentStrong : DesignTokens.accent)
            // Padding inside the label so the padded area is clickable, not merely
            // painted (the filter-pill lesson).
            .padding(.horizontal, DesignTokens.space2)
            .padding(.vertical, 4)
            .background(Capsule().fill(hovering ? DesignTokens.accentBg : Color.clear))
            .overlay(Capsule().strokeBorder(
                hovering ? DesignTokens.accentBorder : DesignTokens.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// The escape hatch out of search mode. It is the primary action in this panel and
/// used to carry less affordance than an inactive filter pill.
private struct ABBackToLeadsButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.space1) {
                Image(systemName: "arrow.uturn.left").font(.system(size: 8, weight: .bold))
                Text("Back to leads").font(.adventor(DesignTokens.textXs, bold: true))
            }
            .foregroundStyle(hovering ? DesignTokens.accentStrong : DesignTokens.accent)
            .padding(.horizontal, DesignTokens.space2)
            .padding(.vertical, 4)
            .background(Capsule().fill(hovering ? DesignTokens.accentBg : Color.clear))
            .overlay(Capsule().strokeBorder(
                hovering ? DesignTokens.accentBorder : DesignTokens.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
        .help("Clear the search and go back to the filtered lead list")
    }
}

/// Status row inside a panel (searching / empty / failed). `centered` places it in
/// the panel's body rather than pinning one muted line to the top-left of a mostly
/// empty surface, which reads as half-loaded rather than calm.
struct ABMessageRow: View {
    enum Tone { case muted, warn }
    let icon: String
    let text: String
    var tone: Tone = .muted
    /// Rotate the glyph while work is genuinely in flight (state-driven, stops the
    /// moment the result lands — never idle motion).
    var spinning: Bool = false
    var centered: Bool = false
    @Environment(\.isStaticRender) private var isStaticRender
    @State private var spin = false

    private var color: Color {
        tone == .warn ? DesignTokens.statusRedText : DesignTokens.textMuted
    }

    private var row: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .rotationEffect(.degrees(spinning && spin ? 360 : 0))
                .animation(spinning ? ABMotion.spin : ABMotion.fast, value: spin)
            Text(text).font(.adventor(DesignTokens.textSm))
                .fixedSize(horizontal: false, vertical: true)
            if !centered { Spacer(minLength: 0) }
        }
        .foregroundStyle(color)
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
        // A still render can't animate; starting the loop there would also make the
        // harness output non-deterministic.
        .onAppear { if spinning && !isStaticRender { spin = true } }
    }

    var body: some View {
        if centered {
            row.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            row
        }
    }
}
