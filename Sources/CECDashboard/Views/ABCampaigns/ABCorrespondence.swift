import SwiftUI

// Drill level 3: everything said (and staged to be said) between our accounts
// and one lead. Chronological cards; direction is a ROLE color (outbound =
// teal identity, inbound = pink — same meaning "replies" already carries in
// the Leads tab). Staged cards are dashed + carry the ONLY write affordance in
// the app: the copy-revision editor (send_queue subject/body overrides).

struct ABCorrespondenceView: View {
    let campaign: CampaignSummary
    let lead: CampaignRosterEntry
    let drill: CampaignDrillModel
    var staticRender: Bool = false
    /// Fixture-only: open the editor on this card at first render, so the
    /// harness can still the editing state (and the placeholder detector
    /// exercises the TextEditor gate). nil in the live app.
    var fixtureEditingId: String? = nil

    /// Keychain write-capability probe, seeded at view-struct init (NOT
    /// onAppear — ImageRenderer stills have no appearance lifecycle, and the
    /// attributes-only probe is cheap). Forced true in the harness.
    @State private var canRevise: Bool
    @State private var editingId: String?
    @State private var draftSubject = ""
    @State private var draftBody = ""
    @Environment(\.isStaticRender) private var isStaticRender

    init(campaign: CampaignSummary, lead: CampaignRosterEntry,
         drill: CampaignDrillModel, staticRender: Bool = false,
         fixtureEditingId: String? = nil) {
        self.campaign = campaign
        self.lead = lead
        self.drill = drill
        self.staticRender = staticRender
        self.fixtureEditingId = fixtureEditingId
        _canRevise = State(initialValue: staticRender || SupabaseWriteClient.isConfigured)
        _editingId = State(initialValue: fixtureEditingId)
        if let fixtureEditingId,
           let item = drill.thread.first(where: { $0.id == fixtureEditingId }) {
            _draftSubject = State(initialValue: item.subject ?? "")
            _draftBody = State(initialValue: item.body ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            context
            captions
            timeline
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // The root's Esc handler must know an editor is open (popping would
        // destroy the draft — delta review). Mirror editingId into the model,
        // and clear the flag if this view unmounts with the editor open.
        .onChange(of: editingId, initial: true) { _, new in
            drill.setEditorOpen(new != nil)
        }
        .onDisappear { drill.setEditorOpen(false) }
    }

    // MARK: Supporting context

    private var context: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space4) {
            if let email = lead.email?.nilIfEmpty {
                Text(email)
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .textSelection(.enabled)
            }
            ABStatusPill(text: lead.status?.nilIfEmpty ?? "—",
                         role: ABCampaignRoles.rosterLead(lead.status ?? ""))
            Spacer()
            if drill.isLoadingThread {
                ProgressView().controlSize(.small).tint(DesignTokens.accent)
            }
            Text("\(drill.thread.count) items")
                .font(.abMono(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textGhost)
        }
    }

    @ViewBuilder
    private var captions: some View {
        if drill.interactionsFailed && !drill.queueFailed {
            ABDegradedCaption(text: "The interaction archive couldn't be read — showing the send queue only.")
        }
        if drill.queueFailed && !drill.interactionsFailed {
            ABDegradedCaption(text: "The send queue couldn't be read — staged messages are missing from this timeline.")
        }
        if drill.threadTruncated {
            ABDegradedCaption(text: "Long history truncated — showing the newest \(CampaignsRepository.correspondenceCap) interactions.")
        }
        if drill.queueTruncated {
            ABDegradedCaption(text: "Send-queue rows truncated at \(CampaignsRepository.queueCap) — newest steps may be missing from this timeline.")
        }
        if !canRevise && drill.thread.contains(where: { $0.isStaged }) {
            ABDegradedCaption(text: "Read-only: no write key in the Keychain, so staged copy can't be revised from here.")
        }
    }

    // MARK: Timeline

    @ViewBuilder
    private var timeline: some View {
        if let message = drill.threadMessage, drill.thread.isEmpty {
            Text(message)
                .font(.adventor(DesignTokens.textBase))
                .foregroundStyle(DesignTokens.textMuted)
                .padding(DesignTokens.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .abSurface(.surface, radius: DesignTokens.radiusLg)
        } else if staticRender {
            cardsStack.frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { cardsStack }
        }
    }

    private var cardsStack: some View {
        LazyVStack(alignment: .leading, spacing: DesignTokens.space3) {
            ForEach(drill.thread) { item in
                card(item, isLatest: item.id == drill.thread.last?.id)
            }
        }
    }

    // MARK: Card

    /// Pill label + role for a timeline item (pure — SelfTest target).
    static func cardLabel(_ item: CorrespondenceItem) -> (text: String, role: ABStatusRole) {
        switch item.kind {
        case .interaction:
            switch (item.direction ?? "") {
            case "inbound":  return ("Inbound", .reward)
            case "outbound": return ("Outbound", .active)
            default:         return ((item.direction ?? "—").capitalized, .neutral)
            }
        case .queued:
            switch item.queueStatus ?? "" {
            case "pending": return ("Staged", .neutral)
            case "sending": return ("Sending", .active)
            case "failed":  return ("Failed", .warn)
            case "bounced": return ("Bounced", .warn)
            case "skipped": return ("Skipped", .neutral)
            case "sent":    return ("Sent", .active)
            default:        return ((item.queueStatus ?? "—").capitalized, .neutral)
            }
        }
    }

    @ViewBuilder
    private func card(_ item: CorrespondenceItem, isLatest: Bool) -> some View {
        let label = Self.cardLabel(item)
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space3) {
                ABStatusPill(text: label.text, role: label.role)
                if let subject = item.subject?.nilIfEmpty {
                    Text(subject)
                        .font(.adventor(DesignTokens.textBase, bold: true))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if item.kind == .queued, item.subject != nil || item.body != nil {
                    // Neutral, not the pink reward role — pink means "inbound
                    // reply" everywhere in this app (design review). "custom
                    // copy" not "revised": VIP campaigns write overrides at
                    // creation, so an override isn't necessarily hand-edited.
                    ABStatusPill(text: "custom copy", role: .neutral)
                }
                if item.fromOtherCampaign {
                    Text("other campaign")
                        .font(.adventor(DesignTokens.textXs))
                        .foregroundStyle(DesignTokens.textGhost)
                }
                Spacer(minLength: 0)
                Text(Self.dateTime(item))
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.textGhost)
            }

            metaLine(item)

            if editingId == item.id {
                editor(item)
            } else {
                bodyText(item)
                if item.isStaged && canRevise {
                    reviseButton(item)
                }
            }
        }
        .padding(DesignTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .abSurface(editingId == item.id || isLatest ? .elevated : .surface,
                   radius: DesignTokens.radiusLg)
        .overlay(
            // Staged = not yet real: dashed outline (brief §3).
            RoundedRectangle(cornerRadius: DesignTokens.radiusLg, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: item.isStaged ? [5, 4] : []))
                .foregroundStyle(item.isStaged ? DesignTokens.borderStrong : Color.clear)
        )
    }

    /// Step/angle wording (pure — SelfTest target). variant_index semantics per
    /// send_queue.sql: on step 1 it selects the copy (angle A/B/C); on later
    /// steps it's the CARRIED-FORWARD step-1 angle for attribution, while the
    /// copy sent is the step's own pool — so it must never read as "variant".
    static func stepLabel(step: Int?, variantIndex: Int?) -> String? {
        guard let step else { return nil }
        guard let idx = variantIndex, idx >= 0 else { return "step \(step)" }
        let angle = idx < 26
            ? String(UnicodeScalar(UInt8(65 + idx)))   // 0→A, 1→B, 2→C…
            : "\(idx)"
        return step == 1 ? "step 1 · angle \(angle)"
                         : "step \(step) · angle \(angle) attributed"
    }

    private func metaLine(_ item: CorrespondenceItem) -> some View {
        HStack(spacing: DesignTokens.space3) {
            if let label = Self.stepLabel(step: item.stepNumber, variantIndex: item.variantIndex) {
                meta(label)
            }
            if let account = item.sendingAccount?.nilIfEmpty { meta("from \(account)") }
            if let to = item.toEmail?.nilIfEmpty { meta("to \(to)") }
            if item.isStaged {
                // Clock glyph per the design brief: staged = scheduled future.
                HStack(spacing: DesignTokens.space1) {
                    Image(systemName: "clock")
                        .font(.system(size: DesignTokens.textXs - 1))
                    Text("scheduled")
                }
                .font(.abMono(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textMuted)
            }
            if (item.queueStatus ?? "") == "sending" {
                meta("in flight — or awaiting delivery confirmation if hours old")
            }
            if let error = item.error?.nilIfEmpty {
                Text(error)
                    .font(.abMono(DesignTokens.textXs))
                    .foregroundStyle(DesignTokens.statusRedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func meta(_ text: String) -> some View {
        Text(text)
            .font(.abMono(DesignTokens.textXs))
            .foregroundStyle(DesignTokens.textMuted)
            .lineLimit(1)
    }

    @ViewBuilder
    private func bodyText(_ item: CorrespondenceItem) -> some View {
        if let body = item.body?.nilIfEmpty {
            Text(body)
                .font(.abMono(DesignTokens.textSm))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if item.bodyUnreadable {
            Text(unreadableNote(item))
                .font(.adventor(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textGhost)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if item.kind == .interaction, (item.direction ?? "") == "inbound" {
            // A reply with no archived text must say so — silence here reads
            // as "empty reply" on the highest-value card in the timeline.
            Text("Reply received — its text wasn't archived.")
                .font(.adventor(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textGhost)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Honest wording per state — an unsent row must never say "sent"; a
    /// bounced row DID send (handle_bounce flips sent→failed post-delivery).
    private func unreadableNote(_ item: CorrespondenceItem) -> String {
        switch item.kind {
        case .interaction:
            return "Sent with the step's pool template — the archived record is subject-only."
        case .queued:
            if item.isStaged {
                return "Copy comes from the step's pool template (not readable with the dashboard key). Posting a revision writes a per-lead override."
            }
            if (item.queueStatus ?? "") == "bounced" {
                return "Delivered then bounced — the sent copy is archived on the outbound card above."
            }
            return "Copy is the step's pool template (not readable with the dashboard key)."
        }
    }

    // MARK: Revision editor (the app's one write surface)

    private func reviseButton(_ item: CorrespondenceItem) -> some View {
        // Disabled while ANY save is in flight — opening a second editor
        // mid-save is how drafts got destroyed (state-machine review F1).
        ABQuietButton(label: "Revise copy", systemImage: "pencil",
                      disabled: drill.isSavingRevision) {
            drill.clearRevisionError()   // a stale error must not pre-load this editor
            editingId = item.id
            draftSubject = item.subject ?? ""
            draftBody = item.body ?? ""
        }
    }

    @ViewBuilder
    private func editor(_ item: CorrespondenceItem) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            // TextField is NSTextField-backed — same ImageRenderer placeholder
            // problem as TextEditor (the campaign-thread-editing still caught
            // it at 19,808 yellow pixels), so stills render the draft as Text.
            if isStaticRender {
                Text(draftSubject.nilIfEmpty ?? "Subject override (empty = step template)")
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(draftSubject.isEmpty
                                     ? DesignTokens.textGhost : DesignTokens.textPrimary)
                    .padding(DesignTokens.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .fill(DesignTokens.bgRoot))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .strokeBorder(DesignTokens.borderDefault, lineWidth: 1))
            } else {
                TextField("Subject override (empty = step template)", text: $draftSubject)
                    .textFieldStyle(.plain)
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .padding(DesignTokens.space2)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .fill(DesignTokens.bgRoot))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .strokeBorder(DesignTokens.borderDefault, lineWidth: 1))
            }

            // TextEditor is NSTextView-backed — ImageRenderer would paint the
            // placeholder block, so stills render the draft as plain text.
            if isStaticRender {
                Text(draftBody.nilIfEmpty ?? " ")
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(DesignTokens.space2)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .fill(DesignTokens.bgRoot))
            } else {
                TextEditor(text: $draftBody)
                    .font(.abMono(DesignTokens.textSm))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 260)
                    .padding(DesignTokens.space1)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .fill(DesignTokens.bgRoot))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                        .strokeBorder(DesignTokens.borderDefault, lineWidth: 1))
            }

            Text("Merge slots like {{greetingLine}} stay live — the sender substitutes them at send time. Leaving both fields empty clears the revision (back to the pool template) — on a VIP campaign that discards the per-lead rephrase. Non-atlasautomates links are refused: the sender would strip them.")
                .font(.adventor(DesignTokens.textXs))
                .foregroundStyle(DesignTokens.textGhost)

            if let error = drill.revisionError {
                ABDegradedCaption(text: error)
            }

            HStack(spacing: DesignTokens.space3) {
                ABQuietButton(label: drill.isSavingRevision ? "Saving…" : "Save revision",
                              systemImage: "checkmark",
                              disabled: drill.isSavingRevision || item.queueId == nil) {
                    guard let queueId = item.queueId else { return }
                    let savedCardId = item.id
                    Task {
                        if await drill.saveRevision(queueId: queueId,
                                                    subject: draftSubject,
                                                    body: draftBody) {
                            // Close only the editor that saved — never a
                            // different card's editor opened meanwhile
                            // (state-machine review F1).
                            if editingId == savedCardId { editingId = nil }
                        }
                    }
                }
                ABQuietButton(label: "Cancel", systemImage: "xmark",
                              disabled: drill.isSavingRevision) {
                    editingId = nil
                }
            }
        }
    }

    // MARK: Formatting

    private static let dateTimeFmt: DateFormatter = {
        let f = DateFormatter()
        // POSIX locale pins the fixed format against the user's 12/24-hour
        // preference mangling HH (platform review).
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f
    }()

    static func dateTime(_ item: CorrespondenceItem) -> String {
        item.date.map { dateTimeFmt.string(from: $0) } ?? "date unknown"
    }
}

// MARK: - Quiet text button (§6 feedback, no chrome competition)

struct ABQuietButton: View {
    let label: String
    let systemImage: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.space1) {
                Image(systemName: systemImage)
                    .font(.system(size: DesignTokens.textXs - 1, weight: .semibold))
                Text(label).font(.adventor(DesignTokens.textXs, bold: true))
            }
            .foregroundStyle(disabled ? DesignTokens.textGhost
                             : hovering ? DesignTokens.accentStrong : DesignTokens.accent)
            .padding(.horizontal, DesignTokens.space3)
            .padding(.vertical, DesignTokens.space1 + 2)
            .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                .fill(hovering && !disabled ? DesignTokens.accentBg : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusSm)
                .strokeBorder(hovering && !disabled ? DesignTokens.accentBorder
                              : DesignTokens.borderDefault, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(ABMotion.fast, value: hovering)
        .onHover { hovering = $0 }
    }
}
