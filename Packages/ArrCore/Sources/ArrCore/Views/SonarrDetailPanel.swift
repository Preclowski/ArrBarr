import SwiftUI
import MediaKit

// MARK: - Sonarr

struct SonarrDetailPanel<Header: View>: View {
    @Environment(ConfigStore.self) var configStore
    let siblings: [QueueItem]
    var isLoading: Bool = false
    let header: Header
    /// TMDB only: Sonarr has no cast endpoint.
    var cast: [CastMember] = []
    var onTapPerson: ((CastMember) -> Void)? = nil
    var trailer: TrailerReel? = nil
    var trailerLoading: Bool = false
    var tmdbSeasons: [Int: TMDBDetails.Airing] = [:]
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
    /// Bumped once the media server's season posters land: the index isn't observable.
    @State private var mediaServerPostersLoaded = false

    private var mediaServerKeys: [MediaServerExternalKey] { sonarrDetail?.mediaServerKeys ?? [] }

    /// The media server's season poster (it carries its own header), then TMDB's, then the series poster
    /// behind the arr's key.
    private func seasonPoster(_ season: Int) -> (url: URL?, apiKey: String?) {
        if mediaServerPostersLoaded, let url = MediaServerIndex.shared.seasonPosterURL(for: mediaServerKeys, season: season) {
            return (url, nil)
        }
        if let url = TMDBClient.imageURL(path: tmdbSeasons[season]?.posterPath) { return (url, nil) }
        return (posterURL, posterRequiresAuth ? posterAPIKey : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !cast.isEmpty {
                CastRow(cast: cast, onTapPerson: onTapPerson)
            } else if isLoading, !configStore.tmdbApiKey.isEmpty {
                // Without a TMDB key the cast never loads, so no skeleton.
                SkeletonCastRow()
            }

            if let trailer {
                TrailerRow(reel: trailer)
            } else if trailerLoading, !configStore.tmdbApiKey.isEmpty {
                // Series trailers only come from TMDB.
                SkeletonTrailerRow()
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
                    SeasonSection(count: visibleSeasons.count) {
                        ForEach(visibleSeasons, id: \.seasonNumber) { season in
                            let poster = seasonPoster(season.seasonNumber)
                            SeasonRow(
                                number: season.seasonNumber,
                                season: season,
                                tmdb: tmdbSeasons[season.seasonNumber],
                                posterURL: poster.url,
                                posterAPIKey: poster.apiKey,
                                watched: MediaServerIndex.shared.isSeasonWatched(
                                    mediaServerKeys, season: season.seasonNumber,
                                    airedEpisodes: season.statistics?.episodeCount ?? 0),
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
            } else if isLoading {
                SkeletonSeasonSection()
            }

            // The series counterpart of a movie's existing-file section: many files, so their total.
            if let stats = sonarrDetail?.statistics, let size = stats.sizeOnDisk, size > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    DetailSectionHeader("Existing files", count: stats.episodeFileCount)
                    ExistingFileBanner(quality: nil, size: size, customFormatScore: nil, customFormats: [], fileName: nil)
                }
            }
        }
        .task(id: sonarrDetail?.id) {
            guard !mediaServerKeys.isEmpty else { return }
            await MediaServerIndex.shared.loadSeasonPosters(for: mediaServerKeys)
            mediaServerPostersLoaded = true
        }
    }

}
