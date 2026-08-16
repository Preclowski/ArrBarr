import Foundation

/// Resolves the YouTube trailer for a title, for both the detail hero's chip
/// and the Quiz's play button. Mirrors `CastProvider`: a small LRU, in-flight
/// coalescing, and the arr payload preferred over TMDB wherever it carries the
/// answer already.
///
/// Movies come from Radarr's own `youTubeTrailerId` when the detail payload has
/// one — no TMDB key involved. Everything else goes to TMDB `/videos`: series
/// always (Sonarr ships no trailer field at all), and movies whose Radarr
/// record has an empty trailer id.
@MainActor
enum TrailerProvider {
    /// Misses stay uncached (see `CoalescingCache`): "no trailer" is often a
    /// dropped request or a TMDB key the user hasn't pasted yet, and pinning
    /// it for the session would hide the chip even after that's fixed.
    private static let cache = CoalescingCache<String, String?>(
        capacity: 60, shouldStore: { $0 != nil })

    // MARK: - Public API

    /// YouTube video id for a movie. `radarrTrailerId` is Radarr's own field —
    /// pass it straight through even when empty; the emptiness check lives here
    /// so no call site has to remember that Radarr sends `""` for "none".
    static func movieTrailerKey(radarrTrailerId: String?, tmdbId: Int?,
                                configStore: ConfigStore) async -> String? {
        if let id = radarrTrailerId, !id.isEmpty { return id }
        guard let tmdbId, tmdbId > 0 else { return nil }
        return await cache.value(for: "movie:\(tmdbId)") {
            await fetch(configStore: configStore) { try await $0.movieVideos(movieId: tmdbId) }
        }
    }

    /// YouTube video id for a series. `tvdbId` is the fallback route for the
    /// series Sonarr didn't ship a `tmdbId` for — same `/find` hop the cast
    /// strip makes.
    static func seriesTrailerKey(tmdbId: Int?, tvdbId: Int?,
                                 configStore: ConfigStore) async -> String? {
        guard (tmdbId ?? 0) > 0 || (tvdbId ?? 0) > 0 else { return nil }
        let key = "series:\(tmdbId.map(String.init) ?? "-"):\(tvdbId.map(String.init) ?? "-")"
        return await cache.value(for: key) {
            await fetch(configStore: configStore) { client in
                var resolved = tmdbId
                if (resolved ?? 0) <= 0, let tvdbId, tvdbId > 0 {
                    resolved = try await client.tvIdFromTVDB(tvdbId)
                }
                guard let id = resolved, id > 0 else { return [] }
                return try await client.tvVideos(tvId: id)
            }
        }
    }

    /// The watch page for a resolved video id. Handed to the OS rather than
    /// played in-app: pulling the stream out of YouTube would break its terms,
    /// and an embedded IFrame player is a bigger build than the chip needs.
    static func watchURL(key: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    // MARK: - Fetch

    private static func fetch(configStore: ConfigStore,
                              _ videos: @escaping (TMDBClient) async throws -> [TMDBVideo]) async -> String? {
        // Demo runs offline by design — no TMDB call, no trailer chip.
        guard !DemoMode.isActive else { return nil }
        let apiKey = configStore.tmdbApiKey
        guard !apiKey.isEmpty else { return nil }
        guard let list = try? await videos(TMDBClient(apiKey: apiKey)) else { return nil }
        return TMDBVideo.bestTrailerKey(list)
    }

}
