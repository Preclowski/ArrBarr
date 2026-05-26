import SwiftUI

// MARK: - Movie (Radarr + Whisparr share the same layout since Whisparr
//          is a Radarr fork operating on the same RadarrMovieDetail type)

struct RadarrDetailPanel: View {
    let item: QueueItem
    @ObservedObject var viewModel: QueueViewModel
    let radarrDetail: RadarrMovieDetail?
    let radarrMovieFile: ArrFile?
    let siblings: [QueueItem]
    let hasActiveDownloads: Bool
    let loadError: String?
    let header: AnyView
    let arrWebURLForItem: (QueueItem) -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let overview = radarrDetail?.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
            }

            // Active downloads first; the existing-file banner reads like a
            // footnote after, since for upgrade-in-progress rows the queue
            // section already shows the "new" file and the banner is the
            // counterpart "old" — natural reading order.
            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    showInlineUpgrade: true,
                    showCustomFormats: true,
                    // Badges moved to the header card above.
                    showListingBadges: false,
                    // Per-item closures (used by MultiRow when this
                    // section renders a list) are only needed for the
                    // multi-item case; for single-item, sticky header
                    // controls (`headerActions`) own the actions.
                    arrWebURLForItem: arrWebURLForItem
                )
            }

            // Standalone "already in library" banner — only when
            // there's no active download. Prefer the separately-
            // fetched `radarrMovieFile` because it carries
            // customFormats; fall back to the stripped inline one
            // from /movie/{id} only when the separate fetch failed.
            if !hasActiveDownloads {
                if let file = radarrMovieFile {
                    ExistingFileBanner(movieFile: file)
                } else if let movieFile = radarrDetail?.movieFile {
                    ExistingFileBanner(movieFile: movieFile)
                }
            }

            if let err = loadError {
                Text(err)
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
