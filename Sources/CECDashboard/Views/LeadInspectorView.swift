import SwiftUI
import Observation

/// P5-2: the read-only lead inspector — search a lead by company or email,
/// then read its FULL pipeline journey (every ledger event across runs) with
/// the input/output snapshots each stage recorded (research JSON, casualized
/// before→after, opener/offer copy, edit diffs). Replaces "ask Claude to pull
/// up lead X six times." Strictly read-only: no edit affordances by design.
@MainActor
@Observable
final class LeadInspectorModel {
    var query = ""
    private(set) var hits: [LeadSearchHit] = []
    private(set) var selected: LeadSearchHit?
    private(set) var events: [PipelineLeadEventRow] = []
    private(set) var eventsTruncated = false
    private(set) var isSearching = false
    private(set) var isLoadingEvents = false
    private(set) var message: String?
    // Newest-wins selection: each select() bumps the generation; a stale fetch
    // landing after a newer tap is discarded instead of overwriting it
    // (swift-semantics review: the old guard silently DROPPED mid-flight taps
    // and could render lead B's header over lead A's events).
    private var selectGeneration = 0

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            message = "Type at least 2 characters of a company name or email."
            return
        }
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        message = nil
        // A new result set orphans the previous selection — clear it so the
        // journey pane can't show a lead that isn't in the list anymore. Also
        // supersede any IN-FLIGHT select(): without the generation bump its
        // late result would repopulate `events` under a nil header (delta review).
        selectGeneration += 1
        selected = nil
        events = []
        eventsTruncated = false
        do {
            let repo = PipelineRepository(client: try SupabaseClient.make())
            hits = try await repo.searchLeads(q)
            if hits.isEmpty { message = "No leads match “\(q)”." }
        } catch {
            hits = []
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func select(_ hit: LeadSearchHit) async {
        selectGeneration += 1
        let generation = selectGeneration
        // Header and events change TOGETHER: never the new lead's name over
        // the previous lead's cards.
        selected = hit
        events = []
        eventsTruncated = false
        message = nil
        isLoadingEvents = true
        defer { if generation == selectGeneration { isLoadingEvents = false } }
        do {
            let repo = PipelineRepository(client: try SupabaseClient.make())
            let fetched = try await repo.leadEvents(leadId: hit.id)
            guard generation == selectGeneration else { return }   // superseded
            events = fetched
            eventsTruncated = fetched.count == PipelineRepository.inspectorEventsCap
            if fetched.isEmpty {
                message = "No pipeline events recorded for this lead (it may predate the run ledger)."
            }
        } catch {
            guard generation == selectGeneration else { return }
            events = []
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct LeadInspectorView: View {
    @Bindable var model: LeadInspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                resultsList
                    .frame(minWidth: 220, maxWidth: 320)
                journey
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Lead inspector — search by company or email…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.search() } }
            Button("Search") { Task { await model.search() } }
                .disabled(model.isSearching)
            if model.isSearching || model.isLoadingEvents {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var resultsList: some View {
        List(model.hits, selection: .constant(model.selected?.id)) { hit in
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.companyName?.nilIfEmpty ?? "Unknown company")
                    .font(.callout.weight(.medium))
                Text(hit.email?.nilIfEmpty ?? "no email")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.select(hit) } }
        }
        .listStyle(.inset)
    }

    private var journey: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let lead = model.selected {
                    Text("\(lead.companyName?.nilIfEmpty ?? "Unknown company") — journey (\(model.events.count) events)")
                        .font(.headline)
                }
                if model.eventsTruncated {
                    Text("Showing the most recent \(PipelineRepository.inspectorEventsCap) events — older history omitted.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // Keyed by a composite: `id` alone is Optional (tolerance-first
                // model), and N nil-id rows would collapse to ONE card under
                // Identifiable identity (swift-semantics review).
                ForEach(model.events, id: \.stableKey) { event in
                    LeadEventCard(event: event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// One ledger event: stage + status header, then the recorded input/output
/// snapshots pretty-printed. Selectable monospaced text — the whole point is
/// reading real values (openers, research, casualizations) without asking.
private struct LeadEventCard: View {
    let event: PipelineLeadEventRow

    // Hoisted: DateFormatter init is expensive and headerTrailer runs per card
    // per body evaluation (code review). Main-actor-confined via the view.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(event.stage?.nilIfEmpty ?? "?")
                    .font(.callout.weight(.semibold))
                Text(event.status?.nilIfEmpty ?? "")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.25), in: Capsule())
                if let reason = event.dropReason?.nilIfEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(headerTrailer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            snapshot("input", event.input)
            snapshot("output", event.output)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var badgeColor: Color {
        switch (event.status ?? "").lowercased() {
        case "ok": return .green
        case "dropped": return .orange
        case "failed": return .red
        default: return .gray
        }
    }

    private var headerTrailer: String {
        let run = event.runId.map { String($0.prefix(8)) } ?? "—"
        let at = event.createdAt.flatMap(DateParse.iso)
            .map { Self.timeFmt.string(from: $0) } ?? "—"
        return "run \(run) · \(at)"
    }

    @ViewBuilder
    private func snapshot(_ label: String, _ value: JSONValue?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value.prettyPrinted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
