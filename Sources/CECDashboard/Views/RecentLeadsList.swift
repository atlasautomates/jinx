import SwiftUI

/// Native, clickable replacement for the old recent-leads table widget (P3).
/// Rows open the in-app lead profile via the shared presenter — same tap
/// idiom as the Pipeline inspector's results list.
struct RecentLeadsList: View {
    let leads: [LeadRow]
    @Environment(ProfilePresenter.self) private var presenter

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionLabel("Recent Leads — click a row for the full profile")
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s3)
            List(leads, id: \.id) { lead in
                row(lead)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        presenter.active = LeadRef(id: lead.id,
                                                   companyName: lead.companyName,
                                                   email: nil)
                    }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(Palette.bgRoot)
    }

    private func row(_ lead: LeadRow) -> some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lead.companyName?.nilIfEmpty ?? "Unknown company")
                    .font(.ui(12, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Text([lead.industry, location(lead)]
                    .compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
                    .nilIfEmpty ?? "—")
                    .font(.ui(11))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if let source = lead.leadSource?.nilIfEmpty {
                Badge(text: source, style: .neutral)
            }
            if let stage = lead.enrichmentStage?.nilIfEmpty {
                Badge(text: stage, style: .blue)
            }
            Text(added(lead))
                .font(.ui(11))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func location(_ lead: LeadRow) -> String? {
        [lead.city, lead.state].compactMap { $0?.nilIfEmpty }
            .joined(separator: ", ").nilIfEmpty
    }

    private func added(_ lead: LeadRow) -> String {
        DateParse.iso(lead.createdAt).map { Self.dayFmt.string(from: $0) } ?? "—"
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}
