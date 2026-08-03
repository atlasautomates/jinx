import SwiftUI

// The Leads tab's lens control. Four single-select menus (lane, region, source,
// industry), ANDed. It sits BELOW the title and ABOVE the KPI hero: it is the
// thing that decides what every number under it means, but it is a control, not
// the focus — so it reads at control weight (muted text, one surface step, no
// glow) and only an ACTIVE dimension takes the teal identity colour (bible §1:
// colour serves hierarchy; §6: state is legible at a glance).

struct ABFilterBar: View {
    let data: ABLeadsData
    /// Called with the new filter whenever a menu changes. The view model owns the
    /// value — this view never mutates it locally, so what the bar draws and what
    /// the numbers were computed from cannot drift.
    var onChange: (LeadFilter) -> Void = { _ in }
    @Environment(\.isStaticRender) private var isStaticRender

    private var filter: LeadFilter { data.filter }

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(filter.isActive ? DesignTokens.accent : DesignTokens.textGhost)

            if data.laneFilterAvailable {
                ABFilterMenu(
                    title: "Lane", selection: filter.lane?.label,
                    options: data.facets.lanes.map { .init(value: $0.lane.label, count: $0.count) },
                    onPick: { picked in
                        var next = filter
                        next.lane = picked.flatMap { label in
                            LeadFilter.Lane.allCases.first { $0.label == label }
                        }
                        onChange(next)
                    })
            } else {
                // The lane reads failed; offering the menu would let the user filter
                // on a classification we know is wrong (see `lanesDegraded`).
                ABUnavailableChip(title: "Lane")
            }

            ABFilterMenu(title: "Region", selection: filter.region, options: data.facets.regions,
                         onPick: { picked in
                             var next = filter; next.region = picked; onChange(next)
                         })
            ABFilterMenu(title: "Source", selection: filter.source, options: data.facets.sources,
                         onPick: { picked in
                             var next = filter; next.source = picked; onChange(next)
                         })
            ABFilterMenu(title: "Industry", selection: filter.industry, options: data.facets.industries,
                         onPick: { picked in
                             var next = filter; next.industry = picked; onChange(next)
                         })

            if filter.isActive {
                ABClearFiltersButton(count: data.matchingCount) { onChange(.all) }
            }

            Spacer(minLength: 0)

            if let note = data.breakdownScopeNote {
                // The snapshot is a window, not the book — every figure on the tab
                // is computed over these rows, so say so where the lens is set.
                Text(note)
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
                    .help("The lead snapshot was capped; figures cover these rows only.")
            }
        }
    }
}

/// One dimension's menu, drawn as a pill. Inactive: muted text, subtle border.
/// Active: the teal identity + the chosen value, so a set filter is visible
/// without reading the menu open.
private struct ABFilterMenu: View {
    let title: String
    let selection: String?
    let options: [FilterFacets.Option]
    let onPick: (String?) -> Void
    @State private var hovering = false
    @Environment(\.isStaticRender) private var isStaticRender

    private var active: Bool { selection != nil }

    var body: some View {
        // `Menu` is AppKit-backed: ImageRenderer paints a yellow placeholder over
        // it, which destroys any still it appears in. On the preview path draw the
        // pill alone (identical chrome, no menu) — the harness only ever needs to
        // show the bar's STATE.
        if isStaticRender {
            label.pillChrome(active: active, hovering: hovering)
        } else {
            // The chrome goes on the MENU, not on its label: a `Menu` composes its
            // label with the system's own indicator and lays the result out itself,
            // so a background/border applied inside the label is dropped — live, the
            // bar rendered as bare text with a leading chevron while the still showed
            // proper pills.
            Menu {
                Button("All \(title.lowercased())s") { onPick(nil) }
                if !options.isEmpty { Divider() }
                ForEach(options) { option in
                    Button {
                        // Re-picking the current value clears it: the pill is then a
                        // toggle, which is what a single-select filter should feel like.
                        onPick(option.value == selection ? nil : option.value)
                    } label: {
                        Text("\(option.value)  (\(option.count))")
                    }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pillChrome(active: active, hovering: hovering)
            .onHover { hovering = $0 }
            .help(active ? "\(title): \(selection ?? "")" : "Filter by \(title.lowercased())")
        }
    }

    private var label: some View {
        HStack(spacing: DesignTokens.space1) {
            Text(active ? title.uppercased() : title)
                .font(.adventor(DesignTokens.textXs, bold: active))
                .tracking(active ? 0.8 : 0)
                .foregroundStyle(active ? DesignTokens.accent : DesignTokens.textMuted)
            if let selection {
                Text(selection)
                    .font(.adventor(DesignTokens.textXs, bold: true))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(active ? DesignTokens.accent : DesignTokens.textGhost)
        }
    }
}

private extension View {
    /// The filter bar's pill: one surface step, teal identity only when the
    /// dimension is set (bible §1 — colour serves hierarchy).
    func pillChrome(active: Bool, hovering: Bool) -> some View {
        self
            .padding(.horizontal, DesignTokens.space2)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? DesignTokens.accentBg
                                              : (hovering ? DesignTokens.bgHighlight : Color.clear)))
            .overlay(Capsule().strokeBorder(
                active ? DesignTokens.accentBorder
                       : (hovering ? DesignTokens.borderHover : DesignTokens.borderDefault),
                lineWidth: 1))
            .contentShape(Capsule())
            .animation(ABMotion.fast, value: hovering)
    }
}

/// A dimension we cannot compute right now — shown disabled rather than hidden,
/// so a missing menu is never mistaken for a missing feature.
private struct ABUnavailableChip: View {
    let title: String

    var body: some View {
        HStack(spacing: DesignTokens.space1) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 8, weight: .semibold))
            Text(title)
                .font(.adventor(DesignTokens.textXs))
        }
        .foregroundStyle(DesignTokens.textGhost)
        .padding(.horizontal, DesignTokens.space2)
        .padding(.vertical, 5)
        .overlay(Capsule().strokeBorder(DesignTokens.borderSubtle, lineWidth: 1))
        .help("Lane data could not be read on this load — filtering by it would be wrong.")
    }
}

/// Clears every dimension at once, and states what the current lens is showing.
private struct ABClearFiltersButton: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.space1) {
                Text(count, format: .number)
                    .font(.abMono(DesignTokens.textXs, weight: .semibold))
                    .foregroundStyle(DesignTokens.accent)
                Text(count == 1 ? "lead" : "leads")
                    .font(.adventor(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textMuted)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? DesignTokens.textPrimary : DesignTokens.textMuted)
            }
            .padding(.horizontal, DesignTokens.space2)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering ? DesignTokens.bgHighlight : Color.clear))
            .overlay(Capsule().strokeBorder(
                hovering ? DesignTokens.borderHover : DesignTokens.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ABMotion.fast, value: hovering)
        .help("Clear all filters")
    }
}
