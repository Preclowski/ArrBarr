import Foundation
import MediaKit

/// Resolves the YouTube trailer for a title, for both the detail hero's chip
/// and the Quiz's play button. Mirrors `CastProvider`: the arr payload is
/// preferred over TMDB wherever it carries the answer already.
///
/// Movies come from Radarr's own `youTubeTrailerId` when the detail payload has
/// one — no TMDB key involved. Everything else goes to TMDB `/videos`: series
/// always (Sonarr ships no trailer field at all), and movies whose Radarr
/// record has an empty trailer id.
enum TrailerProvider {

    // MARK: - Public API

    /// YouTube video id for a movie. `radarrTrailerId` is Radarr's own field —
    /// pass it straight through even when empty; the emptiness check lives here
    /// so no call site has to remember that Radarr sends `""` for "none".
    static func movieTrailerKey(radarrTrailerId: String?, tmdbId: Int?,
                                configStore: ConfigStore) async -> String? {
        if let id = radarrTrailerId, !id.isEmpty { return id }
        // Demo has no TMDB key, so the real lookup can only ever answer nil and
        // the trailer button would never appear. The fixtures carry their own
        // ids — see `DemoMocks.trailerKey`.
        guard let tmdbId, tmdbId > 0 else { return nil }
        return await fetch(configStore: configStore) { try await $0.movieVideos(movieId: tmdbId) }
    }

    /// YouTube video id for a series. `tvdbId` is the fallback route for the
    /// series Sonarr didn't ship a `tmdbId` for — same `/find` hop the cast
    /// strip makes.
    static func seriesTrailerKey(tmdbId: Int?, tvdbId: Int?,
                                 configStore: ConfigStore) async -> String? {
        guard (tmdbId ?? 0) > 0 || (tvdbId ?? 0) > 0 else { return nil }
        return await fetch(configStore: configStore) { client in
            var resolved = tmdbId
            if (resolved ?? 0) <= 0, let tvdbId, tvdbId > 0 {
                resolved = try await client.tvIdFromTVDB(tvdbId)
            }
            guard let id = resolved, id > 0 else { return [] }
            return try await client.tvVideos(tvId: id)
        }
    }

    // MARK: - Fetch

    private static func fetch(configStore: ConfigStore,
                              _ videos: @escaping (TMDBClient) async throws -> [TMDBVideo]) async -> String? {
        let apiKey = configStore.tmdbApiKey
        guard !apiKey.isEmpty else { return nil }
        guard let list = try? await videos(TMDBClient(apiKey: apiKey)) else { return nil }
        return TMDBVideo.bestTrailerKey(list)
    }

}
