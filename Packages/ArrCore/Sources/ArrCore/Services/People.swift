import Foundation
import os
import MediaKit

/// TMDB people data for the person view, cast tooltip and people search. Ownership is
/// tagged from the library on each call, so a title added a minute ago reads as owned.
enum People {
    /// `SeriesIdentity` on purpose: the filmography line answers the same "which show?"
    /// question as `SeriesIdentityResolver`, so one predicate returns both.
    private static let log = Logger(category: "SeriesIdentity")

    // MARK: - Public API

    /// nil without a TMDB key; a failed lookup throws.
    static func details(personId: Int, tmdbKey key: String) async throws -> TMDBPersonDetails? {
        if DemoMode.isActive { return DemoMocks.personDetails(personId: personId) }
        guard !key.isEmpty else { return nil }
        return try await TMDBClient(apiKey: key).personDetails(personId: personId)
    }

    /// Popularity-desc, year-desc, the same order the chat credits tools use.
    static func movieFilmography(personId: Int, tmdbKey key: String, radarrConfig: ServiceConfig) async throws -> [SearchResult] {
        if DemoMode.isActive { return DemoMocks.personMovies(personId: personId) }
        guard !key.isEmpty else { return [] }
        let credits = try await TMDBClient(apiKey: key).personMovieCredits(personId: personId)
        let libraryMap = await ArrLibraryMaps.radarrByTMDBId(config: radarrConfig)
        let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
        return TMDBSearchMapping.movies(PersonCreditMerge.byPopularity(merged.credits), libraryMap: libraryMap, roles: merged.roles)
    }

    /// The tvdbId a row needs is resolved on tap by `SeriesIdentityResolver`, never here,
    /// so a filmography costs one credits call.
    static func seriesFilmography(personId: Int, tmdbKey key: String, sonarrConfig: ServiceConfig) async throws -> [SearchResult] {
        if DemoMode.isActive { return DemoMocks.personSeries(personId: personId) }
        guard !key.isEmpty else { return [] }
        let credits = try await TMDBClient(apiKey: key).personTVCredits(personId: personId)
        // Ownership by TMDB id off the shared `LibraryIndex`, never by title + year.
        let libraryMap = await ArrLibraryMaps.sonarrByTMDBId(config: sonarrConfig)
        let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
        let rows = TMDBSearchMapping.series(
            PersonCreditMerge.byPopularity(merged.credits),
            libraryMap: libraryMap, roles: merged.roles)
        // Owned rows bypass `SeriesIdentityResolver` and its log, so the pairing is recorded here.
        for row in rows where row.inLibraryArrId != nil {
            log.notice("""
                filmography: "\(row.title, privacy: .private)" (\(row.year ?? 0, privacy: .public)) \
                tmdb tv \(row.tmdbTVId ?? 0, privacy: .public) → sonarr series \
                \(row.inLibraryArrId ?? 0, privacy: .public)
                """)
        }
        return rows
    }
}
