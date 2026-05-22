import SwiftUI

public struct UpcomingRowView: View {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore

    private var shouldBlur: Bool {
        configStore.shouldBlurPoster(for: item.source)
    }

    public var body: some View {
        Button {
            guard let entityId = item.entityId else { return }
            DetailRequest.post(
                DetailRequest.syntheticItem(
                    source: item.source,
                    entityId: entityId,
                    title: item.title,
                    posterURL: item.posterURL,
                    posterRequiresAuth: item.posterRequiresAuth
                )
            )
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(item.entityId == nil)
        .help(tooltipText)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            PosterBlurContainer(blurred: shouldBlur, cornerRadius: 3) {
                RemotePoster(
                    url: item.posterURL,
                    apiKey: item.posterRequiresAuth ? apiKeyForSource : nil,
                    size: posterSize,
                    cornerRadius: 3,
                    fallbackSymbol: item.source.symbol
                )
            }

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
                Text(item.airDateFormatted(locale: configStore.currentLocale))
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
        .contentShape(Rectangle())
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 24, height: 36)
        case .lidarr: return CGSize(width: 24, height: 24)
        }
    }

    private var apiKeyForSource: String? {
        configStore.serviceConfig(for: item.source).apiKey
    }

    private var tooltipText: String {
        var lines = [item.title]
        if let sub = item.subtitle { lines.append(sub) }
        lines.append(item.airDateFormatted(locale: configStore.currentLocale))
        if let overview = item.overview, !overview.isEmpty {
            lines.append("")
            lines.append(overview)
        }
        return lines.joined(separator: "\n")
    }
}
