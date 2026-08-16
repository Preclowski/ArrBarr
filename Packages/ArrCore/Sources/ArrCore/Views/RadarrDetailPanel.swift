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

    /// True only when the download section's own `└─ OLD` sub-line is showing
    /// the file on disk, which makes the standalone block below it a
    /// duplicate.
    ///
    /// That happens for exactly one shape: a single active grab that is an
    /// upgrade AND arrived with the `existing*` fields populated. Two grabs
    /// collapse the section into the compact multi-row list, which drops the
    /// diff on purpose (one shared old file repeated per row is noise) — and
    /// the old rule, "hide the block whenever anything is downloading", then
    /// hid the fact everywhere. The same gap swallowed a lone non-upgrade grab
    /// of a movie that already had a file.
    private var downloadsCarryExistingFile: Bool {
        // `siblings.count` (not the active count) is the split DownloadSection
        // itself uses to choose single vs. multi layout — mirror it exactly, or
        // this predicate disagrees with what's actually on screen.
        guard hasActiveDownloads, siblings.count <= 1 else { return false }
        return item.isUpgrade && item.hasExistingFileMetadata
    }

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

            // Standalone "already in library" block — shown unless the
            // download section is already carrying the same fact inline.
            // Prefer the separately-fetched `radarrMovieFile` because it
            // carries customFormats; fall back to the stripped inline one
            // from /movie/{id} only when the separate fetch failed.
            //
            // The `library` chip moved into the hero card next to the
            // title (DetailView passes it via `titleBadge`) — membership
            // is a property of the TITLE, not of one file. The block
            // itself is captioned "Existing file" instead.
            if !downloadsCarryExistingFile {
                if let file = radarrMovieFile ?? radarrDetail?.movieFile {
                    VStack(alignment: .leading, spacing: 6) {
                        DetailSectionHeader("Existing file")
                        ExistingFileBanner(movieFile: file)
                    }
                }
            }

            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }
}
