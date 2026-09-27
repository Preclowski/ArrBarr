import SwiftUI
import MediaKit

// MARK: - Sonarr

struct SonarrDetailPanel<Header: View>: View {
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
    @Binding var sonarrDetail: ArrSeries?
    /// Tap handler for a season row — DetailView pushes `SeasonDetailView`.
    let onTapSeason: (ArrSeason) -> Void
    /// Flip one season's monitored flag straight from its row. The host owns
    /// the write (optimistic flip + Sonarr call + refetch).
    var onSetSeasonMonitored: ((ArrSeason, Bool) async -> Void)? = nil
    /// Row context-menu search for one season. Both nil → the rows carry no
    /// menu (the host owns both the arr call and the release-list push).
    var onAutomaticSeasonSearch: ((ArrSeason) async -> Void)? = nil
    var onManualSeasonSearch: ((ArrSeason) -> Void)? = nil
    /// Earliest episode still to air; nil hides the section.
    var nextEpisode: ArrEpisode? = nil
    /// Series artwork for the next-episode row's tooltip (episodes have none).
    var posterURL: URL? = nil
    var posterRequiresAuth: Bool = false
    var posterAPIKey: String? = nil

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

            if let next = nextEpisode {
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("detail.nextEpisode.label")
                    EpisodeRow(
                        episode: next,
                        queueItems: siblings.filter {
                            $0.arrQueueId != 0 && $0.seasonNumber == next.seasonNumber
                                && $0.episodeNumber == next.episodeNumber
                        },
                        onTap: { ep in
                            if let season = sonarrDetail?.seasons?.first(where: { $0.seasonNumber == ep.seasonNumber }) {
                                onTapSeason(season)
                            }
                        },
                        posterURL: posterURL,
                        posterRequiresAuth: posterRequiresAuth,
                        posterAPIKey: posterAPIKey
                    )
                }
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
                                    onTap: { onTapSeason(season) },
                                    onSetMonitored: onSetSeasonMonitored.map { set in
                                        { monitored in await set(season, monitored) }
                                    },
                                    onAutomaticSearch: onAutomaticSeasonSearch.map { search in
                                        { await search(season) }
                                    },
                                    onManualSearch: onManualSeasonSearch.map { search in
                                        { search(season) }
                                    }
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
