import os
import Foundation

/// TMDB's per-episode score: neither Sonarr nor TVDB ship one. The tmdb id is resolved
/// from the tvdb id when Sonarr didn't ship it.
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
        let client = configStore.tmdbClient
        guard let seriesId = await client.seriesId(tmdbId: tmdbId, tvdbId: tvdbId),
              let hit = await Logger.extras.attempt("episode rating", { try await client.episodeRating(tvId: seriesId, season: season, episode: episode) }) ?? nil
        else { return nil }
        return Rating(value: hit.value, votes: hit.votes)
    }
}
