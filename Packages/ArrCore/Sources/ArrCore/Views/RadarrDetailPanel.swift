import SwiftUI
import MediaKit

// MARK: - Movie (Radarr + Whisparr share the same layout since Whisparr
//          is a Radarr fork operating on the same ArrMovie type)

struct RadarrDetailPanel<Header: View>: View {
    let item: QueueItem
    let radarrDetail: ArrMovie?
    let radarrMovieFile: ArrFile?
    let siblings: [QueueItem]
    let hasActiveDownloads: Bool
    let loadError: String?
    var isLoading: Bool = false
    let header: Header
    /// From Radarr `/credit`.
    var cast: [CastMember] = []
    var onTapPerson: ((CastMember) -> Void)? = nil
    let arrWebURLForItem: (QueueItem) -> URL?
    /// The header CTA only controls the focused row, so two grabs of one movie need per-row controls.
    var onPauseItem: ((QueueItem) -> Void)? = nil
    var onResumeItem: ((QueueItem) -> Void)? = nil
    var onDeleteItem: ((QueueItem) -> Void)? = nil

    /// True only when the download section's `└─ OLD` sub-line already shows the file on disk:
    /// a single upgrade grab with `existing*` populated. The multi-row list drops that diff.
    private var downloadsCarryExistingFile: Bool {
        // `siblings.count` is what DownloadSection splits single vs multi on; mirror it exactly.
        guard hasActiveDownloads, siblings.count <= 1 else { return false }
        return item.isUpgrade && item.hasExistingFileMetadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: onTapPerson)
            } else if isLoading {
                SkeletonCastRow()
            }

            if hasActiveDownloads {
                DownloadSection(
                    items: siblings,
                    focused: item,
                    showCustomFormats: true,
                    showListingBadges: false,
                    onPauseItem: onPauseItem,
                    onResumeItem: onResumeItem,
                    onDeleteItem: onDeleteItem,
                    arrWebURLForItem: arrWebURLForItem
                )
            }

            // Prefer the separately fetched `radarrMovieFile` (it carries customFormats) over
            // the stripped inline one from /movie/{id}.
            if !downloadsCarryExistingFile {
                if let file = radarrMovieFile ?? radarrDetail?.movieFile {
                    VStack(alignment: .leading, spacing: 6) {
                        DetailSectionHeader("Existing file")
                        ExistingFileBanner(file: file)
                    }
                }
            }

            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }
}
