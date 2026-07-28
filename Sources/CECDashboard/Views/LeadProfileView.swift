import SwiftUI

/// The in-app lead dossier (P3) — a native render of the lead-profile skill's
/// page: header + sentiment, contact facts, personalization (casualized
/// values, opener, offer), and the conversation timeline. Deterministic reads
/// only; strictly read-only.
struct LeadProfileView: View {
    let ref: LeadRef
    /// Preview seam (`--screenshot profile`): injected inputs skip the Supabase
    /// load entirely, so a still render needs no network and no Keychain.
    var previewInputs: ProfileInputs?
    /// Forced copy-affordance state for still renders — a screenshot can't
    /// hover or click, so the harness names which field shows which state.
    var copyDemo = CopyDemo()
    /// Drop the ScrollView for a plain stack: ImageRenderer captures a
    /// ScrollView's viewport as empty (same flag as ABLeadsView).
    var staticRender = false

    @State private var model = LeadProfileModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(PinsModel.self) private var pinsModel

    /// Injected fixture wins; otherwise whatever the fetch landed.
    private var profile: ProfileInputs? { previewInputs ?? model.inputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .background(Palette.bgRoot)
        .task(id: ref.id) {
            guard previewInputs == nil else { return }
            await model.load(ref)
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.lead.displayName
                     ?? ref.companyName?.nilIfEmpty ?? "Lead")
                    .font(.display(18, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
            }
            if let sentiment = profile?.sentiment {
                Badge(text: sentiment, style: statusStyle(for: sentiment))
            }
            if let tier = profile?.enrichment?.leadTier?.nilIfEmpty {
                Badge(text: "tier \(tier)", style: .blue)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            // Pin under the FETCHED identity when available — the entry-point
            // ref may lack the company/email the chip wants to display.
            Button {
                pinsModel.toggle(pinRef)
            } label: {
                Label(pinsModel.isPinned(ref.id) ? "Unpin" : "Pin",
                      systemImage: pinsModel.isPinned(ref.id) ? "pin.slash" : "pin")
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Space.s4)
    }

    /// The richest identity available for the pin chip (fetched > entry ref).
    private var pinRef: LeadRef {
        LeadRef(id: ref.id,
                companyName: profile?.lead.companyName?.nilIfEmpty
                    ?? ref.companyName,
                email: profile?.lead.email?.nilIfEmpty ?? ref.email)
    }

    private var subtitle: String {
        let company = profile?.lead.companyName?.nilIfEmpty
            ?? ref.companyName?.nilIfEmpty
        let email = profile?.lead.email?.nilIfEmpty ?? ref.email?.nilIfEmpty
        return [company, email].compactMap { $0 }.joined(separator: " · ")
            .nilIfEmpty ?? "—"
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.message {
            VStack {
                Spacer()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let inputs = profile {
            loaded(inputs)
        } else {
            VStack { Spacer(); ProgressView(); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func loaded(_ inputs: ProfileInputs) -> some View {
        if staticRender {
            sections(inputs)
        } else {
            ScrollView { sections(inputs) }
        }
    }

    private func sections(_ inputs: ProfileInputs) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if inputs.partial {
                Text("Partial dossier — an enrichment or conversation read failed; sections may be missing.")
                    .font(.ui(12))
                    .foregroundStyle(StatusStyle.orange.fg)
            }
            factsSection(inputs.lead)
            if let enrichment = inputs.enrichment {
                personalizationSection(enrichment)
            }
            conversationSection(inputs)
            if let research = inputs.enrichment?.webResearchJson {
                researchSection(research)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s4)
    }

    // MARK: - Sections

    private func factsSection(_ lead: LeadDetailRow) -> some View {
        profileCard("Contact") {
            factGrid(ProfileFacts.contact(lead))
            if let desc = lead.companyDescription?.nilIfEmpty {
                Text(desc)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func personalizationSection(_ e: LeadEnrichmentRow) -> some View {
        profileCard("Personalization") {
            factGrid(ProfileFacts.personalization(e))
            copyBlock("Opener", e.personalizedOpener)
            copyBlock("Offer", e.personalizedOffer)
        }
    }

    private func conversationSection(_ inputs: ProfileInputs) -> some View {
        profileCard("Conversation (\(inputs.interactions.count))") {
            if inputs.interactions.isEmpty {
                // A FAILED read is not an empty conversation (reliability).
                Text(inputs.interactionsFailed
                     ? "Conversation unavailable — the interactions read failed."
                     : "No interactions recorded.")
                    .font(.ui(12))
                    .foregroundStyle(inputs.interactionsFailed
                                     ? StatusStyle.orange.fg : Palette.textMuted)
            }
            if inputs.interactionsTruncated {
                Text("Showing the most recent \(ProfileRepository.interactionsCap) interactions.")
                    .font(.ui(11))
                    .foregroundStyle(StatusStyle.orange.fg)
            }
            ForEach(Array(inputs.interactions.enumerated()), id: \.offset) { _, item in
                interactionBubble(item)
            }
        }
    }

    private func researchSection(_ research: JSONValue) -> some View {
        profileCard("Research (raw)") {
            DisclosureGroup("web_research_json") {
                Text(research.prettyPrinted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.ui(12))
            .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: - Pieces

    private func profileCard(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionLabel(title)
            body()
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(Palette.bgSurface))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Palette.borderDefault, lineWidth: 1))
    }

    /// Every short atomic fact is click-to-copy — this dossier exists to be
    /// pasted into a CRM, a search bar, or a reply, and hand-selecting a field
    /// was the tax. Selection is dropped on THESE values deliberately: a
    /// selectable Text swallows the click that would copy it, and an email or
    /// phone is always wanted whole. Prose keeps its selection — see copyBlock.
    ///
    /// Identity is the whole Fact, not the label: labels are a fixed vocabulary
    /// shared by every lead, so keying on them alone would let a row's copied
    /// state survive a content swap and assert "Copied" over a different value.
    private func factGrid(_ facts: [ProfileFacts.Fact]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.s4, verticalSpacing: Space.s1) {
            ForEach(facts, id: \.self) { fact in
                GridRow {
                    Text(fact.label)
                        .font(.ui(11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .gridColumnAlignment(.trailing)
                    CopyableValue(value: fact.value, label: fact.label,
                                  demo: demoState(for: fact.label))
                }
            }
        }
    }

    /// The generated opener/offer. This is prose you lift a sentence out of, so
    /// the text STAYS selectable and the copy trigger moves to a glyph button
    /// beside the label — selection and click-to-copy coexist instead of
    /// competing for the same click.
    @ViewBuilder
    private func copyBlock(_ label: String, _ text: String?) -> some View {
        if let text = text.flatMap(ProfileFacts.blockValue) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s2) {
                    Text(label)
                        .font(.ui(11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                    CopyableValue(value: text, label: label, style: .glyph,
                                  demo: demoState(for: label))
                    Spacer()
                }
                Text(text)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s2)
                    .background(RoundedRectangle(cornerRadius: Radius.md)
                        .fill(Palette.bgElevated))
            }
        }
    }

    /// The demo seam is honored ONLY on the preview path. Live, it is always
    /// `.none`, so no forced "Copied" checkmark can ever appear over a real
    /// lead's field that nobody clicked.
    private func demoState(for label: String) -> CopyDemoState {
        previewInputs == nil ? .none : copyDemo.state(for: label)
    }

    private func interactionBubble(_ item: LeadInteractionRow) -> some View {
        let inbound = (item.direction ?? "").lowercased() == "inbound"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s2) {
                Badge(text: item.direction?.nilIfEmpty ?? item.interactionType ?? "event",
                      style: inbound ? .purple : .neutral)
                if let subject = item.subject?.nilIfEmpty {
                    Text(subject)
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Text(timeText(item.interactionAt))
                    .font(.ui(11))
                    .foregroundStyle(Palette.textMuted)
            }
            if let body = (item.transcript?.nilIfEmpty ?? item.summary?.nilIfEmpty) {
                Text(body)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md)
            .fill(inbound ? StatusStyle.purple.bg : Palette.bgElevated))
    }

    private func timeText(_ iso: String?) -> String {
        DateParse.iso(iso).map { Self.timeFmt.string(from: $0) } ?? "—"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}

// File-private: module scope would add a second sentiment→style mapping table
// next to DesignTokens' statusForLabel (swift-semantics review).
private func statusStyle(for sentiment: String) -> StatusStyle {
    switch sentiment.lowercased() {
    case "positive", "interested": return .green
    case "negative", "unsubscribe", "not_interested": return .red
    case "neutral", "question": return .blue
    default: return .neutral
    }
}
