import SwiftUI
import MediaKit

// MARK: - Sonarr

struct SonarrDetailPanel<Header: View>: View {
    @EnvironmentObject var configStore: ConfigStore
    let siblings: [QueueItem]
    let loadError: String?
    var isLoading: Bool = false
    let header: Header
    /// TMDB only: Sonarr has no cast endpoint.
    var cast: [CastMember] = []
    var onTapPerson: ((CastMember) -> Void)? = nil
    @Binding var sonarrDetail: ArrSeries?
    let onTapSeason: (ArrSeason) -> Void
    /// The host owns the write (optimistic flip, Sonarr call, refetch).
    var onSetSeasonMonitored: ((ArrSeason, Bool) async -> Void)? = nil
    /// Both nil: the rows carry no menu.
    var onAutomaticSeasonSearch: ((ArrSeason) async throws -> Void)? = nil
    var onManualSeasonSearch: ((ArrSeason) -> Void)? = nil
    var nextEpisode: ArrEpisode? = nil
    /// Episodes have no artwork of their own.
    var posterURL: URL? = nil
    var posterRequiresAuth: Bool = false
    var posterAPIKey: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: onTapPerson)
            } else if isLoading, !configStore.tmdbApiKey.isEmpty {
                // Without a TMDB key the cast never loads, so no skeleton.
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
                    VStack(alignment: .leading, spacing: 6) {
                        DetailSectionHeader("detail.seasons.button", count: visibleSeasons.count)
                        VStack(spacing: 3) {
                            ForEach(visibleSeasons, id: \.seasonNumber) { season in
                                SeasonRow(
                                    season: season,
                                    // By season number straight off the queue siblings, so no episode join can miss.
                                    queueItems: siblings.filter {
                                        $0.arrQueueId != 0 && $0.seasonNumber == season.seasonNumber
                                    },
                                    onTap: { onTapSeason(season) },
                                    onSetMonitored: onSetSeasonMonitored.map { set in
                                        { monitored in await set(season, monitored) }
                                    },
                                    onAutomaticSearch: onAutomaticSeasonSearch.map { search in
                                        { try await search(season) }
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
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("detail.seasons.button")
                    SkeletonRows(count: 6)
                }
            }

            if let err = loadError {
                LoadErrorLine(message: err)
            }
        }
    }

}
