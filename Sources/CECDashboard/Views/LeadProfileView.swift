import SwiftUI

/// The in-app lead dossier (P3) — a native render of the lead-profile skill's
/// page: header + sentiment, contact facts, personalization (casualized
/// values, opener, offer), and the conversation timeline. Deterministic reads
/// only; strictly read-only.
struct LeadProfileView: View {
    let ref: LeadRef
    @State private var model = LeadProfileModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(PinsModel.self) private var pinsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .background(Palette.bgRoot)
        .task(id: ref.id) { await model.load(ref) }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.inputs?.lead.displayName
                     ?? ref.companyName?.nilIfEmpty ?? "Lead")
                    .font(.display(18, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .font(.ui(12))
                    .foregroundStyle(Palette.textSecondary)
            }
            if let sentiment = model.inputs?.sentiment {
                Badge(text: sentiment, style: statusStyle(for: sentiment))
            }
            if let tier = model.inputs?.enrichment?.leadTier?.nilIfEmpty {
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
                companyName: model.inputs?.lead.companyName?.nilIfEmpty
                    ?? ref.companyName,
                email: model.inputs?.lead.email?.nilIfEmpty ?? ref.email)
    }

    private var subtitle: String {
        let company = model.inputs?.lead.companyName?.nilIfEmpty
            ?? ref.companyName?.nilIfEmpty
        let email = model.inputs?.lead.email?.nilIfEmpty ?? ref.email?.nilIfEmpty
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
        } else if let inputs = model.inputs {
            loaded(inputs)
        } else {
            VStack { Spacer(); ProgressView(); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    private func loaded(_ inputs: ProfileInputs) -> some View {
        ScrollView {
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
    }

    // MARK: - Sections

    private func factsSection(_ lead: LeadDetailRow) -> some View {
        profileCard("Contact") {
            factGrid([
                ("Title", lead.jobTitle),
                ("Industry", lead.industry),
                ("Location", locationText(lead)),
                ("Phone", lead.phone),
                ("Website", lead.website),
                ("Email", lead.email),
            ])
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
            factGrid([
                ("Casual name", e.casualizedFirstName),
                ("Casual company", e.casualizedCompanyName),
                ("Casual city", e.casualizedCityName),
                ("Project ref", e.personalizationProject),
                ("Detail", e.personalizationDetail),
                ("Source", e.enrichmentSource),
                ("Status", e.enrichmentStatus),
            ])
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

    private func factGrid(_ facts: [(String, String?)]) -> some View {
        let present = facts.compactMap { label, value -> (String, String)? in
            guard let v = value?.nilIfEmpty else { return nil }
            return (label, v)
        }
        return Grid(alignment: .leading, horizontalSpacing: Space.s4, verticalSpacing: 4) {
            ForEach(Array(present.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.0)
                        .font(.ui(11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .gridColumnAlignment(.trailing)
                    Text(fact.1)
                        .font(.ui(12))
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func copyBlock(_ label: String, _ text: String?) -> some View {
        if let text = text?.nilIfEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.ui(11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
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

    private func locationText(_ lead: LeadDetailRow) -> String? {
        lead.location?.nilIfEmpty
            ?? [lead.city, lead.state].compactMap { $0?.nilIfEmpty }
                .joined(separator: ", ").nilIfEmpty
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
