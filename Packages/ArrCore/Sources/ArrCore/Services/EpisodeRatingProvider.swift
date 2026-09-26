import Foundation

/// TMDB's per-episode score, for the episode detail's rating pill.
///
/// The series' own rating (TVDB, via Sonarr) says nothing about the episode on
/// screen, and neither Sonarr nor TVDB ship a per-episode one — TMDB is the
/// only source. Same shape as `CastProvider`: a small cache and in-flight
/// coalescing, keyed per episode, with the series' tmdb id resolved from its
/// tvdb id when Sonarr didn't ship one.
@MainActor
enum EpisodeRatingProvider {
    struct Rating: Equatable, Sendable {
        let value: Double
        let votes: Int
    }

    /// Misses stay uncached: an unrated episode usually just aired, and
    /// pinning "no rating" would keep the pill missing for the session.
    private static let cache = CoalescingCache<String, Rating?>(capacity: 60, shouldStore: { $0 != nil })

    static func rating(tmdbId: Int?, tvdbId: Int?, season: Int?, episode: Int?,
                       configStore: ConfigStore) async -> Rating? {
        guard let season, let episode, !configStore.tmdbApiKey.isEmpty else { return nil }
        let key = "ep:\(tmdbId.map(String.init) ?? "-"):\(tvdbId.map(String.init) ?? "-"):\(season):\(episode)"
        return await cache.value(for: key) {
            await fetch(tmdbId: tmdbId, tvdbId: tvdbId, season: season, episode: episode, configStore: configStore)
        }
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
