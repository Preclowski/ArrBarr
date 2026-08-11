import SwiftUI

// MARK: - Movie (Radarr + Whisparr share the same layout since Whisparr
//          is a Radarr fork operating on the same RadarrMovieDetail type)

struct RadarrDetailPanel<Header: View>: View {
    let item: QueueItem
    let radarrDetail: RadarrMovieDetail?
    let radarrMovieFile: ArrFile?
    let siblings: [QueueItem]
    let hasActiveDownloads: Bool
    let loadError: String?
    /// Detail fetch still in flight — sections with no data yet show a
    /// skeleton instead of nothing, so the view fills in element-by-element.
    var isLoading: Bool = false
    let header: Header
    /// Cast (from Radarr `/credit`) — horizontal headshot strip under header.
    var cast: [CastMember] = []
    /// Tapping a cast head opens the person view — the host (DetailView) owns
    /// the push target.
    var onTapPerson: ((CastMember) -> Void)? = nil
    let arrWebURLForItem: (QueueItem) -> URL?
    /// Per-item queue actions for the multi-download list (two grabs of the
    /// same movie) — the header CTA only controls the focused row, so each
    /// list row needs its own pause/resume/cancel.
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Synopsis now renders inside the header card's right column
            // (beside the poster) — see MediaHeaderCard.overview.
            header

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: onTapPerson)
            } else if isLoading {
                SkeletonCastRow()
            }

            // Active downloads first; the existing-file banner reads like a
            // footnote after, since for upgrade-in-progress rows the queue
            // section already shows the "new" file and the banner is the
            // counterpart "old" — natural reading order.
            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    showCustomFormats: true,
                    // Badges moved to the header card above.
                    showListingBadges: false,
                    // Per-item closures power MultiRow's hover cluster +
                    // context menu when this section renders a list (two
                    // active grabs of the same movie). Single-item keeps
                    // using the sticky header controls, which act on the
                    // focused row.
                    onPauseItem: onPauseItem,
                    onResumeItem: onResumeItem,
                    onDeleteItem: onDeleteItem,
                    arrWebURLForItem: arrWebURLForItem
                )
            }

            // Standalone "already in library" banner — only when
            // there's no active download. Prefer the separately-
            // fetched `radarrMovieFile` because it carries
            // customFormats; fall back to the stripped inline one
            // from /movie/{id} only when the separate fetch failed.
            //
            // Lead with the same `library` status badge the list rows
            // wear, so a detail reached from the Upcoming tab shows the
            // "you already own this" status the way a queue-reached
            // detail leads with its Downloading/Upgrade status chip.
            if !hasActiveDownloads {
                if let file = radarrMovieFile {
                    InLibraryBadge()
                    ExistingFileBanner(movieFile: file)
                } else if let movieFile = radarrDetail?.movieFile {
                    InLibraryBadge()
                    ExistingFileBanner(movieFile: movieFile)
                }
            }

            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }
}
