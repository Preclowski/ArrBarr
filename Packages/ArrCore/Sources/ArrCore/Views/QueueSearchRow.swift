import SwiftUI

/// Queue row for the search layout, on `SearchResultRow` chrome so all result rows share one rhythm.
struct QueueSearchRow: View {
    let item: QueueItem
    /// Set when the row stands for several downloads of one series.
    var series: QueueTitleGroup? = nil
    let onTap: () -> Void

    @Environment(ConfigStore.self) var configStore

    init(item: QueueItem, series: QueueTitleGroup? = nil, onTap: @escaping () -> Void) {
        self.item = item
        self.series = series
        self.onTap = onTap
    }

    var body: some View {
        PosterMetadataRow(
            posterURL: item.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: item.source),
            posterFallbackSymbol: item.source.symbol,
            posterLibraryMark: LibraryMark(downloaded: item.isUpgrade),
            title: item.title,
            metadataSegments: metadataSegments,
            // No section headers in this layout, so each row carries its own "In queue" badge.
            onTap: onTap,
            titleBadge: {
                HStack(spacing: 4) {
                    SourceGlyphChip(source: item.source)
                    InQueueBadge()
                }
            }
        ) {
            Text(statusText)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard let series, series.downloads.contains(where: { $0.status == .downloading }) else {
            return QueueSearchStatusLabel.label(for: item)
        }
        return series.aggregateProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    /// No release name: it has no counterpart in the search rows and breaks their rhythm.
    private var metadataSegments: [String] {
        if let series {
            return [String.localizedStringWithFormat(
                NSLocalizedString("queue.titleGroup.downloadsCount", bundle: .module, comment: ""),
                series.downloadCount
            )]
        }
        return [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }
}
