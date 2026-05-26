import SwiftUI

/// Compact queue-row used in the IN QUEUE section of the queue tab's
/// status-grouped search layout. Shares row chrome with
/// `SearchResultRow` so library / new / queue rows scan as one list
/// rhythm during search. Drills into `DetailView` on tap — pause /
/// resume / delete live there. The full-fat `QueueRowView` (progress
/// bar + inline actions) is still used in the empty-filter default
/// view.
public struct QueueSearchRow: View {
    let item: QueueItem
    let onTap: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    public init(item: QueueItem, onTap: @escaping () -> Void) {
        self.item = item
        self.onTap = onTap
    }

    public var body: some View {
        PosterMetadataRow(
            posterURL: item.posterURL,
            posterAPIKey: nil,
            posterSize: CGSize(width: 26, height: 38),
            posterBlurred: configStore.shouldBlurPoster(for: item.source),
            title: item.title,
            metadataSegments: metadataSegments,
            // Arr identity + "In queue" status badge — section
            // headers were dropped, so each row carries its own
            // disposition signal directly in the title slot.
            titleBadge: AnyView(HStack(spacing: 4) {
                SourceGlyphChip(source: item.source)
                InQueueBadge()
            }),
            onTap: onTap
        ) {
            Text(QueueSearchStatusLabel.label(for: item))
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }

    /// Mirror `SearchResultRow`'s rhythm: lead with the subtitle (the
    /// same first-line metadata library/new rows show), skip
    /// release-name detail — release strings are noisy and have no
    /// counterpart in the search rows, so including them breaks the
    /// "one list rhythm" the status-grouped surface is going for.
    private var metadataSegments: [String] {
        [
            item.subtitle.flatMap { $0.isEmpty ? nil : $0 },
        ].compactMap { $0 }
    }
}
