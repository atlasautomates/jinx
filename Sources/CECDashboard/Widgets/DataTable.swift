import SwiftUI

struct DataTableView: View {
    let data: TableData

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionLabel(data.title)

            // Header
            HStack(spacing: Space.s3) {
                ForEach(Array(data.columns.enumerated()), id: \.offset) { _, col in
                    Text(col.label)
                        .font(.ui(11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, Space.s1)

            Rectangle()
                .fill(Palette.borderDefault)
                .frame(height: 1)

            // Rows
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(data.rows.indices, id: \.self) { ri in
                        let row = data.rows[ri]
                        HStack(spacing: Space.s3) {
                            ForEach(Array(data.columns.enumerated()), id: \.offset) { _, col in
                                cell(for: col, in: row)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, Space.s2)

                        if ri < data.rows.count - 1 {
                            Rectangle()
                                .fill(Palette.borderSubtle)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for col: TableColumn, in row: [String: CellValue]) -> some View {
        let value = row[col.key]
        if col.variant == "badge", let text = value?.displayString {
            Badge(text: text, style: statusForLabel(text))
        } else {
            Text(displayText(for: col, value: value))
                .font(.ui(13))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
    }

    private func displayText(for col: TableColumn, value: CellValue?) -> String {
        guard let value else { return "—" }
        if let d = value.doubleValue, col.format != nil {
            return formatValue(d, col.format)
        }
        return value.displayString
    }
}
