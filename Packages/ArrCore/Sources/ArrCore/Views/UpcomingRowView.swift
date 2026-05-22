import SwiftUI

public struct UpcomingRowView: View {
    let item: UpcomingItem
    @EnvironmentObject var configStore: ConfigStore

    public var body: some View {
        PosterMetadataRow(
            posterURL: item.posterURL,
            posterAPIKey: item.posterRequiresAuth ? apiKeyForSource : nil,
            posterSize: posterSize,
            posterBlurred: configStore.shouldBlurPoster(for: item.source),
            posterFallbackSymbol: item.source.symbol,
            title: item.title,
            metadataSegments: metadataSegments,
            disabled: item.entityId == nil,
            onTap: openDetail
        ) {
            // hasFile is the only "indicator" left after metadata folded
            // everything else into the dot-joined line. Keep it as a tiny
            // trailing affordance so a row that's already on disk reads at
            // a glance — mirrors how `+` keeps its plus icon trailing.
            if item.hasFile {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
        }
        .help(tooltipText)
    }

    /// Dot-joined metadata mirroring `SearchResultRow`. Order: subtitle
    /// (S00E00 etc) → releaseType (Airing / Digital / In Cinemas) →
    /// IMDb → runtime. airDate is deliberately *not* here — the upcoming
    /// list groups by day with the date as a section header, so showing
    /// it again per row would just be noise.
    private var metadataSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
            item.releaseType.flatMap { $0.isEmpty ? nil : $0 },
            item.imdb.map { String(format: "IMDb %.1f", $0) },
            item.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
        ].compactMap { $0 }
    }

    private func openDetail() {
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
    }

    private var posterSize: CGSize {
        switch item.source {
        case .radarr, .sonarr, .whisparr: return CGSize(width: 26, height: 38)
        case .lidarr: return CGSize(width: 26, height: 26)
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
