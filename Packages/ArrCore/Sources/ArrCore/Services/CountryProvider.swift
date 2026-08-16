import Foundation

/// Country of production for a title, as ISO 3166-1 alpha-2 codes.
///
/// TMDB-only by necessity: the Radarr movie and Sonarr series resources carry
/// no country field at all (they stop at `originalLanguage`), so without a
/// TMDB key configured this simply returns nothing and the metadata row drops
/// the segment — the same graceful degradation the cast strip already has.
///
/// Shares `CastProvider`'s shape (per-title coalescing cache, demo branch) so
/// opening the same title from the queue and from search doesn't refetch.
@MainActor
enum CountryProvider {
    /// Misses stay uncached (see `CoalescingCache`) — an empty result is
    /// usually "no TMDB key yet" or a fetch blip, and pinning it would keep
    /// the segment missing for the rest of the session.
    private static let cache = CoalescingCache<String, [String]>(
        capacity: 60, shouldStore: { !$0.isEmpty })

    // MARK: - Public API

    static func movieCountries(tmdbId: Int?, demoMovieId: Int?, configStore: ConfigStore) async -> [String] {
        if DemoMode.isActive {
            return demoMovieId.map { DemoMocks.radarrMovieCountries(movieId: $0) } ?? []
        }
        guard let tmdbId, tmdbId > 0 else { return [] }
        return await cache.value(for: "movie:\(tmdbId)") {
            let key = configStore.tmdbApiKey
            guard !key.isEmpty else { return [] }
            return (try? await TMDBClient(apiKey: key).movieCountries(movieId: tmdbId)) ?? []
        }
    }

    /// Series countries. `tmdbId` is tried first; when Sonarr didn't ship one,
    /// `tvdbId` is resolved via TMDB `/find` — the same fallback the cast strip
    /// needs, and for the same reason.
    static func seriesCountries(tmdbId: Int?, tvdbId: Int?, demoSeriesId: Int?, configStore: ConfigStore) async -> [String] {
        if DemoMode.isActive {
            return demoSeriesId.map { DemoMocks.sonarrSeriesCountries(seriesId: $0) } ?? []
        }
        let key = "series:\(tmdbId.map(String.init) ?? "-"):\(tvdbId.map(String.init) ?? "-")"
        return await cache.value(for: key) {
            let apiKey = configStore.tmdbApiKey
            guard !apiKey.isEmpty else { return [] }
            let client = TMDBClient(apiKey: apiKey)
            var resolved = tmdbId
            if resolved == nil || resolved == 0, let tvdbId, tvdbId > 0 {
                resolved = try? await client.tvIdFromTVDB(tvdbId)
            }
            guard let id = resolved, id > 0 else { return [] }
            return (try? await client.tvCountries(tvId: id)) ?? []
        }
    }

    // MARK: - Display

    /// Localized country names for a code list, capped at `limit` so a
    /// four-country co-production doesn't push the metadata row onto a second
    /// line. Codes the locale can't name fall back to the raw code.
    nonisolated static func displayNames(_ codes: [String], locale: Locale, limit: Int = 2) -> [String] {
        codes.prefix(limit).map { locale.localizedString(forRegionCode: $0) ?? $0 }
    }
}
