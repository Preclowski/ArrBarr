import SwiftUI

/// Queue row for the search layout, on `SearchResultRow` chrome so all result rows share one rhythm.
struct QueueSearchRow: View {
    let item: QueueItem
    let onTap: () -> Void

    @Environment(ConfigStore.self) var configStore

    init(item: QueueItem, onTap: @escaping () -> Void) {
        self.item = item
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
            Text(QueueSearchStatusLabel.label(for: item))
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }

    /// No release name: it has no counterpart in the search rows and breaks their rhythm.
    private var metadataSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }
}
