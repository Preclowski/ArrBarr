import SwiftUI

// MARK: - Sonarr

struct SonarrDetailPanel<Header: View>: View {
    let item: QueueItem
    @EnvironmentObject var configStore: ConfigStore
    let siblings: [QueueItem]
    let loadError: String?
    /// Detail fetch still in flight — the seasons list / cast show a skeleton
    /// instead of nothing, so the view fills in element-by-element.
    var isLoading: Bool = false
    let header: Header
    /// Cast (TMDB — Sonarr has no cast endpoint) — horizontal headshot strip.
    var cast: [CastMember] = []
    /// Tapping a cast head opens the person view (host owns the push target).
    var onTapPerson: ((CastMember) -> Void)? = nil
    @Binding var sonarrDetail: SonarrSeriesDetail?
    /// Tap handler for a season row — DetailView pushes `SeasonDetailView`.
    let onTapSeason: (SonarrSeasonInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Synopsis now renders inside the header card's right column
            // (beside the poster) — see MediaHeaderCard.overview.
            header

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: onTapPerson)
            } else if isLoading, !configStore.tmdbApiKey.isEmpty {
                // Series cast comes from TMDB and only with a key (Sonarr has no
                // cast endpoint). No key → it will never load, so don't pulse a
                // skeleton for heads that aren't coming.
                SkeletonCastRow()
            }

            if let seasons = sonarrDetail?.seasons {
                let visibleSeasons = seasons.filter { $0.seasonNumber > 0 }
                if !visibleSeasons.isEmpty {
                    // Header + rows share a 6pt stack (the CastRow rhythm) so
                    // the label hugs its list instead of floating 12pt above.
                    VStack(alignment: .leading, spacing: 6) {
                        DetailSectionHeader("detail.seasons.button", count: visibleSeasons.count)
                        // Each season is a progress-bar summary row; tapping it pushes
                        // SeasonDetailView (its episodes + that season's search buttons).
                        VStack(spacing: 3) {
                            ForEach(visibleSeasons, id: \.seasonNumber) { season in
                                SeasonRow(
                                    season: season,
                                    // Straight off the queue siblings by season
                                    // number — no episode join to miss.
                                    queueItems: siblings.filter {
                                        $0.arrQueueId != 0 && $0.seasonNumber == season.seasonNumber
                                    },
                                    onTap: { onTapSeason(season) }
                                )
                            }
                        }
                    }
                }
            } else if isLoading {
                // Series detail still loading — skeleton the seasons list (its
                // main content) so the surface isn't an empty column.
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("detail.seasons.button")
                    SkeletonRows(count: 6)
                }
            }
            // DownloadSection used to live here for series — the
            // separate "w kolejce" list with all active episode
            // downloads. Removed: each in-progress episode is now
            // marked inline (status dot on the row + hover actions
            // for pause/resume/remove), and the season pill carries
            // a "currently downloading" indicator so the user can
            // jump to the right season without scrolling a parallel
            // list. One source of truth per episode = fewer surfaces
            // for the action buttons to land out of reach.

            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }

}
