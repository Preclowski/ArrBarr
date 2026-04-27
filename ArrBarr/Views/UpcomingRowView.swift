import SwiftUI

struct UpcomingRowView: View {
    let item: UpcomingItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.source == .sonarr ? "tv" : "film")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(item.airDateFormatted)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    if let type = item.releaseType {
                        Text(type)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    if item.hasFile {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .help(tooltipText)
    }

    private var tooltipText: String {
        var lines = [item.title]
        if let sub = item.subtitle { lines.append(sub) }
        lines.append(item.airDateFormatted)
        if let overview = item.overview, !overview.isEmpty {
            lines.append("")
            lines.append(overview)
        }
        return lines.joined(separator: "\n")
    }
}
