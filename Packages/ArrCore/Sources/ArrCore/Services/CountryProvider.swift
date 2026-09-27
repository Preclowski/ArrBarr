import Foundation

/// Country of production for a title, as ISO 3166-1 alpha-2 codes.
///
/// TMDB-only by necessity: the Radarr movie and Sonarr series resources carry
/// no country field at all (they stop at `originalLanguage`), so without a
/// TMDB key configured this simply returns nothing and the metadata row drops
/// the segment — the same graceful degradation the cast strip already has.

enum CountryProvider {

    // MARK: - Public API

    static func movieCountries(tmdbId: Int?, configStore: ConfigStore) async -> [String] {
        guard let tmdbId, tmdbId > 0 else { return [] }
        guard !configStore.tmdbApiKey.isEmpty else { return [] }
        return (try? await configStore.tmdbClient.movieCountries(movieId: tmdbId)) ?? []
    }

    /// Series countries. `tmdbId` is tried first; when Sonarr didn't ship one,
    /// `tvdbId` is resolved via TMDB `/find` — the same fallback the cast strip
    /// needs, and for the same reason.
    static func seriesCountries(tmdbId: Int?, tvdbId: Int?, configStore: ConfigStore) async -> [String] {
        guard !configStore.tmdbApiKey.isEmpty else { return [] }
        let client = configStore.tmdbClient
        guard let id = await client.seriesId(tmdbId: tmdbId, tvdbId: tvdbId) else { return [] }
        return (try? await client.tvCountries(tvId: id)) ?? []
    }

    // MARK: - Display

    /// Localized country names for a code list, capped at `limit` so a
    /// four-country co-production doesn't push the metadata row onto a second
    /// line. Codes the locale can't name fall back to the raw code.
    nonisolated static func displayNames(_ codes: [String], locale: Locale, limit: Int = 2) -> [String] {
        codes.prefix(limit).map { locale.localizedString(forRegionCode: $0) ?? $0 }
    }
}
