import SwiftUI

struct StatusBoardView: View {
    let data: StatusBoardData

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionLabel(data.title)

            VStack(spacing: Space.s2) {
                // Index-keyed: live data may repeat a group label.
                ForEach(Array(data.groups.enumerated()), id: \.offset) { _, group in
                    let style = StatusStyle(token: group.status)
                    HStack(spacing: Space.s3) {
                        Circle()
                            .fill(style.fg)
                            .frame(width: 8, height: 8)
                        Text(group.label)
                            .font(.ui(13))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: Space.s2)
                        Text("\(group.count)")
                            .font(.dataMono(14, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .padding(.vertical, Space.s1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
