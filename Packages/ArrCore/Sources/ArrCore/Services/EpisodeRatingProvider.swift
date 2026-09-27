import Foundation

/// TMDB's per-episode score, for the episode detail's rating pill.
///
/// The series' own rating (TVDB, via Sonarr) says nothing about the episode on
/// screen, and neither Sonarr nor TVDB ship a per-episode one — TMDB is the
/// only source. The series' tmdb id is resolved from its tvdb id when Sonarr
/// didn't ship one.
enum EpisodeRatingProvider {
    struct Rating: Equatable, Sendable {
        let value: Double
        let votes: Int
    }

    static func rating(tmdbId: Int?, tvdbId: Int?, season: Int?, episode: Int?,
                       configStore: ConfigStore) async -> Rating? {
        guard let season, let episode, !configStore.tmdbApiKey.isEmpty else { return nil }
        return await fetch(tmdbId: tmdbId, tvdbId: tvdbId, season: season, episode: episode, configStore: configStore)
    }

    private static func fetch(tmdbId: Int?, tvdbId: Int?, season: Int, episode: Int,
                              configStore: ConfigStore) async -> Rating? {
        let client = TMDBClient(apiKey: configStore.tmdbApiKey)
        var seriesId = tmdbId
        if seriesId == nil || seriesId == 0, let tvdbId, tvdbId > 0 {
            seriesId = try? await client.tvIdFromTVDB(tvdbId)
        }
        guard let seriesId, seriesId > 0,
              let hit = try? await client.episodeRating(tvId: seriesId, season: season, episode: episode)
        else { return nil }
        return Rating(value: hit.value, votes: hit.votes)
    }
}
