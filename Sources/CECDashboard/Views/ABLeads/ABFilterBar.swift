import SwiftUI

// The Leads tab's lens control. Four single-select menus (lane, region, source,
// industry), ANDed. It sits BELOW the title and ABOVE the KPI hero: it is the
// thing that decides what every number under it means, but it is a control, not
// the focus — so it reads at control weight (muted text, one surface step, no
// glow) and only an ACTIVE dimension takes the teal identity colour (bible §1:
// colour serves hierarchy; §6: state is legible at a glance).

struct ABFilterBar: View {
    let data: ABLeadsData
    // NOTE: this bar deliberately takes no `searching` flag. An earlier cut dimmed
    // the pills during a search on the grounds that a lit pill asserts a scope over
    // rows it doesn't govern — but search replaces only the LIST; the heroes, both
    // trends and all four breakdowns stay filtered. Dimming told the user the lens
    // was off while most of the screen was still under it. The disclaimer belongs on
    // the panel that actually ignores the filters, and it lives there.
    /// The lens the USER asked for — what the menus SHOW and edit. Supplied by the
    /// view model, which owns it; deliberately not carried on `data`, so a view
    /// making a claim about the rows cannot reach it by accident.
    var requestedFilter: LeadFilter = .all
    /// Called with the new filter whenever a menu changes. The view model owns the
    /// value — this view never mutates it locally, so what the bar draws and what
    /// the numbers were computed from cannot drift.
    var onChange: (LeadFilter) -> Void = { _ in }
    @Environment(\.isStaticRender) private var isStaticRender

    /// The bar edits the REQUESTED filter, never the effective one: when a
    /// dimension is suppressed (degraded lane reads), editing the effective value
    /// would write the suppression back and permanently discard the user's pick.
    private var filter: LeadFilter { requestedFilter }

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                // The icon asserts "a lens is applied", so it tracks the EFFECTIVE
                // filter — a suppressed dimension must not light it.
                .foregroundStyle(data.effectiveFilter.isActive ? DesignTokens.accent : DesignTokens.textGhost)

            // Keyed on `rawValue`, not on the display label: routing a selection
            // back through human-readable text means renaming a label silently
            // breaks the control (the lookup returns nil and reads as "All").
            // (The lane dimension can no longer degrade independently — its
            // inputs ride the essential v_cec_leads read since the 7.2 remap —
            // so the old ABUnavailableChip fallback is structurally gone.)
            ABFilterMenu(
                title: "Lane", selection: filter.lane?.rawValue,
                display: { LeadFilter.Lane(rawValue: $0)?.label ?? $0 },
                options: data.facets.lanes.map { .init(value: $0.lane.rawValue, count: $0.count) },
                                    onPick: { picked in
                    var next = filter
                    next.lane = picked.flatMap(LeadFilter.Lane.init(rawValue:))
                    onChange(next)
                })

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

            if data.effectiveFilter.isActive {
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
            if data.statusRowsMissing > 0 {
                // A broken write-path invariant (leads with no lead_status row)
                // renders with default-looking axes — disclose it rather than let
                // NULL masquerade as a state (p7a5's stated purpose for the flag).
                Text("\(data.statusRowsMissing) missing status rows")
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.statusRedText)
                    .help("These leads have no lead_status row — their lane and stage "
                        + "render from defaults, and the pipeline's write invariant is "
                        + "broken for them. Worth a doctor run.")
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
    /// Maps a stored option value to its display text (identity by default; the
    /// lane menu stores `rawValue` and displays a human label).
    var display: (String) -> String = { $0 }
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
            label.pillPadding().pillChrome(active: active, hovering: hovering)
        } else {
            // PADDING INSIDE the label, CHROME outside. Both halves are load-bearing
            // and they pull in opposite directions:
            //
            // - A background/border applied inside a `Menu`'s label is dropped (the
            //   menu composes the label with its own indicator and lays the result
            //   out itself), so the fill and the border must go on the outside.
            // - But the menu's CLICK TARGET is its label. Padding applied outside
            //   enlarges the drawn capsule without enlarging the hit region, so the
            //   pill lit up on hover across its whole area (the hover modifier is on
            //   the outer view) while only the text was actually clickable. Reported
            //   as "takes a couple of tries depending on where I click".
            //
            // Padding the label makes the label the size of the capsule, so the two
            // finally agree.
            Menu {
                Button("All \(title.lowercased())s") { onPick(nil) }
                if !options.isEmpty { Divider() }
                ForEach(options) { option in
                    Button {
                        // Re-picking the current value clears it: the pill is then a
                        // toggle, which is what a single-select filter should feel like.
                        onPick(option.value == selection ? nil : option.value)
                    } label: {
                        Text("\(display(option.value))  (\(option.count))")
                    }
                }
            } label: {
                label.pillPadding()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pillChrome(active: active, hovering: hovering)
            .onHover { hovering = $0 }
            .help(active ? "\(title): \(selection.map(display) ?? "")"
                         : "Filter by \(title.lowercased())")
            .accessibilityLabel("Filter by \(title.lowercased())")
            .accessibilityValue(selection.map(display) ?? "All")
        }
    }

    private var label: some View {
        HStack(spacing: DesignTokens.space1) {
            Text(active ? title.uppercased() : title)
                .font(.adventor(DesignTokens.textXs, bold: active))
                // Matches ABSectionLabel's tracking: same uppercase/bold/textXs role,
                // so the two must not disagree by 0.6pt.
                .tracking(active ? 1.4 : 0)
                .foregroundStyle(active ? DesignTokens.accent : DesignTokens.textMuted)
            if let selection {
                Text(display(selection))
                    .font(.adventor(DesignTokens.textXs, bold: true))
                    .foregroundStyle(active ? DesignTokens.textPrimary : DesignTokens.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: DesignTokens.filterValueMaxWidth, alignment: .leading)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(active ? DesignTokens.accent : DesignTokens.textGhost)
                // Decorative: VoiceOver otherwise reads "Region, Chevron Down, pop
                // up button".
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The filter bar's pill: one surface step, teal identity only when the
    /// dimension is set (bible §1 — colour serves hierarchy).
    ///
    /// The ACTIVE state has its own hover step. It used to consume the whole
    /// channel — `active ? accentBg : (hovering ? …)` — so the pills the user
    /// clicks most, the ones already set, were the only controls on the tab that
    /// answered a pointer with nothing. Same failure class as the copy-target
    /// finding in learnings.md: an emphasis state eating the channel feedback
    /// needed.
    /// The pill's interior. Applied to a control's LABEL (inside a `Menu`, inside a
    /// `Button`) so the padded area is part of the hit region, not just of the
    /// drawing. Generous on purpose: these are small targets in a dense bar.
    func pillPadding() -> some View {
        self
            .padding(.horizontal, DesignTokens.space3)
            .padding(.vertical, DesignTokens.controlPaddingY)
            .contentShape(Capsule())
    }

    func pillChrome(active: Bool, hovering: Bool) -> some View {
        self
            .background(Capsule().fill(
                active ? (hovering ? DesignTokens.accentBgHover : DesignTokens.accentBg)
                       : (hovering ? DesignTokens.bgHighlight : Color.clear)))
            .overlay(Capsule().strokeBorder(
                active ? (hovering ? DesignTokens.accentStrong : DesignTokens.accentBorder)
                       : (hovering ? DesignTokens.borderHover : DesignTokens.borderDefault),
                lineWidth: 1))
            .contentShape(Capsule())
            .animation(ABMotion.fast, value: hovering)
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
            .padding(.vertical, DesignTokens.controlPaddingY)
            .background(Capsule().fill(hovering ? DesignTokens.bgHighlight : Color.clear))
            .overlay(Capsule().strokeBorder(
                hovering ? DesignTokens.borderHover : DesignTokens.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ABMotion.fast, value: hovering)
        .help("Clear all filters")
        .accessibilityLabel("Clear all filters, showing \(count) leads")
    }
}
