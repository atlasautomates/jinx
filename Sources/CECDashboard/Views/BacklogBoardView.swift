import SwiftUI
import Observation

/// P6: the healing-backlog board — the dead-end picture `ce doctor` prints,
/// as a live surface: bucket counts by blocking_reason + per-cohort
/// breakdown, enrollment-excluded exactly like the doctor. Read-only;
/// refreshed on the Leads/Campaigns 10-min cadence + manual refresh.
@MainActor
@Observable
final class BacklogViewModel {
    private(set) var inputs: BacklogInputs?
    /// When `inputs` last loaded successfully — the staleness banner shows it
    /// so an operator can gauge HOW stale (reliability review).
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    private(set) var message: String?
    private var generation = 0

    func load() async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let repo = BacklogRepository(client: try SupabaseClient.make())
            let fetched = try await repo.fetch()
            guard gen == generation else { return }
            inputs = fetched
            loadedAt = Date()
            message = nil
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            // Keep last-good inputs on screen; the message explains staleness.
            message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

/// What each bucket takes to clear — the "what do I do about it" column the
/// user otherwise asks Claude for.
private let reasonHints: [String: String] = [
    "unedited": "script-edit pass — `ce doctor --heal` (~1 Sonnet call/lead)",
    "no_opener": "re-personalize with the cohort's offer file",
    "no_offer": "re-personalize with the cohort's offer file",
    "off_target": "excluded by the ICP gate — verify vaulted",
    "undeliverable": "verification proved the email dead — correctly out",
    "no_email": "lead-email-discovery, then verify",
]

struct BacklogBoardView: View {
    let model: BacklogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: 8) {
                SectionLabel("Healing Backlog (dead-ends, enrollment-excluded)")
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let message = model.message {
                HStack(spacing: Space.s2) {
                    Text(model.inputs == nil
                         ? message
                         : "Showing backlog from \(loadedAtText) — refresh failed: \(message)")
                        .font(.ui(12))
                        .foregroundStyle(StatusStyle.orange.fg)
                    // Every other pane has a retry seam; a first-load failure
                    // must not wedge until the 10-min tick (reliability review).
                    Button("Retry") { Task { await model.load() } }
                        .disabled(model.isLoading)
                }
            }
            if let inputs = model.inputs {
                loaded(inputs)
            } else if model.message == nil {
                Text("Scanning…")
                    .font(.ui(12))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bgRoot)
    }

    @ViewBuilder
    private func loaded(_ inputs: BacklogInputs) -> some View {
        if inputs.byReason.isEmpty {
            Text("No dead-ends — every non-enrolled lead is either campaign-ready or in flight."
                 + (inputs.alreadyEnrolled > 0
                    ? " (\(inputs.alreadyEnrolled) flagged lead(s) excluded: already enrolled.)" : ""))
                .font(.ui(12))
                .foregroundStyle(Palette.textSecondary)
        } else {
            // Bucket badges, largest first — generic over whatever reasons
            // exist. Horizontally scrollable: a clipped badge is a silently
            // hidden category (platform review).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s2) {
                    ForEach(inputs.byReason.sorted {
                        $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
                    }, id: \.key) { reason, count in
                        Badge(text: "\(reason) \(count)", style: badgeStyle(reason))
                            .help(reasonHints[reason] ?? "unrecognized reason")
                    }
                    if inputs.alreadyEnrolled > 0 {
                        Text("+\(inputs.alreadyEnrolled) excluded (already enrolled)")
                            .font(.ui(11))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
            }
            if inputs.scanTruncated {
                Text("Dead-end scan hit its page budget — counts are a floor.")
                    .font(.ui(11))
                    .foregroundStyle(StatusStyle.orange.fg)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // Offset identity: the list is replaced wholesale per load
                    // and rows carry no state (P3 timeline precedent).
                    ForEach(Array(inputs.cohorts.enumerated()), id: \.offset) { _, cohort in
                        HStack(spacing: Space.s3) {
                            Text("\(cohort.count)")
                                .font(.dataMono(12, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                                .frame(width: 44, alignment: .trailing)
                            Text("\(cohort.source) / \(cohort.query)")
                                .font(.ui(12))
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var loadedAtText: String {
        model.loadedAt.map { Self.timeFmt.string(from: $0) } ?? "earlier"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private func badgeStyle(_ reason: String) -> StatusStyle {
        switch reason {
        case "unedited": return .orange
        case "no_opener", "no_offer", "no_email": return .purple
        case "off_target": return .neutral
        case "undeliverable": return .red
        default: return .blue
        }
    }
}
