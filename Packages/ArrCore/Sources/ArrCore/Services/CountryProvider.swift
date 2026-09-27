import Foundation

/// ISO 3166-1 alpha-2 production countries. TMDB-only: Radarr/Sonarr resources
/// carry no country field, so without a TMDB key this returns nothing.

enum CountryProvider {

    // MARK: - Public API

    static func movieCountries(tmdbId: Int?, configStore: ConfigStore) async -> [String] {
        guard let tmdbId, tmdbId > 0 else { return [] }
        guard !configStore.tmdbApiKey.isEmpty else { return [] }
        return (try? await configStore.tmdbClient.movieCountries(movieId: tmdbId)) ?? []
    }

    /// Without a `tmdbId`, `tvdbId` is resolved via TMDB `/find`.
    static func seriesCountries(tmdbId: Int?, tvdbId: Int?, configStore: ConfigStore) async -> [String] {
        guard !configStore.tmdbApiKey.isEmpty else { return [] }
        let client = configStore.tmdbClient
        guard let id = await client.seriesId(tmdbId: tmdbId, tvdbId: tvdbId) else { return [] }
        return (try? await client.tvCountries(tvId: id)) ?? []
    }

    // MARK: - Display

    /// Capped so co-productions don't wrap the metadata row.
    nonisolated static func displayNames(_ codes: [String], locale: Locale, limit: Int = 2) -> [String] {
        codes.prefix(limit).map { locale.localizedString(forRegionCode: $0) ?? $0 }
    }
}
