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
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textGhost)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, 6)
        .background(Capsule().fill(DesignTokens.bgSurface))
        .overlay(Capsule().strokeBorder(
            focused ? DesignTokens.accentBorder : DesignTokens.borderDefault, lineWidth: 1))
        .frame(width: 300)
        .animation(ABMotion.fast, value: focused)
        // ⌘F focuses the box from anywhere on the tab.
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// The hit list. Replaces the recent-leads panel while a search is on screen, so
/// the tab never shows two competing lists — and states plainly that it is showing
/// search results over the WHOLE book, not the filtered view underneath.
struct ABSearchResultsPanel: View {
    let state: LeadSearchModel.SearchState
    var staticRender: Bool = false
    var onSelect: ((ABLeadsData.Lead) -> Void)? = nil
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            header
            content
        }
        .padding(.vertical, DesignTokens.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .abSurface(.surface, radius: DesignTokens.radiusLg)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.space2) {
            ABSectionLabel("Search results")
            if case .results(_, let hits) = state {
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
            Spacer()
            Text("whole lead book · filters not applied")
                .font(.adventor(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textGhost)
            Button(action: onClear) {
                Text("Back to leads")
                    .font(.adventor(DesignTokens.textXs, bold: true))
                    .foregroundStyle(DesignTokens.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignTokens.space3)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()
        case .searching:
            ABMessageRow(icon: "hourglass", text: "Searching…", tone: .muted)
        case .failed(_, let message):
            // A failed search must never look like "no such lead".
            ABMessageRow(icon: "exclamationmark.triangle", text: message, tone: .warn)
        case .results(let term, let hits):
            if hits.isEmpty {
                ABMessageRow(icon: "questionmark.circle",
                             text: "No lead matches “\(term)”.", tone: .muted)
            } else {
                ABLeadRowsTable(leads: hits, staticRender: staticRender, onSelect: onSelect)
            }
        }
    }
}

/// One-line status row inside a panel (searching / empty / failed).
struct ABMessageRow: View {
    enum Tone { case muted, warn }
    let icon: String
    let text: String
    var tone: Tone = .muted

    private var color: Color {
        tone == .warn ? DesignTokens.statusRedText : DesignTokens.textMuted
    }

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.adventor(DesignTokens.textSm))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
    }
}
