import Foundation
import os
import MediaKit

/// TMDB people data — biography and filmography — for the person view, the
/// cast tooltip and people search. Every read goes through the store, which
/// coalesces concurrent asks and keeps the answers; ownership is tagged from
/// the library on each call, so a title added a minute ago reads as owned.
enum People {
    /// Deliberately `SeriesIdentity` rather than a category of this type's own:
    /// the filmography line below answers the same "which show did that map
    /// to?" question as `SeriesIdentityResolver`, and one predicate should
    /// return both halves.
    private static let log = Logger(category: "SeriesIdentity")

    // MARK: - Public API

    /// Biography / age / birthplace / external ids. nil without a TMDB key or
    /// on a failed lookup.
    static func details(personId: Int, tmdbKey key: String) async -> TMDBPersonDetails? {
        if DemoMode.isActive { return DemoMocks.personDetails(personId: personId) }
        guard !key.isEmpty else { return nil }
        return try? await TMDBClient(apiKey: key).personDetails(personId: personId)
    }

    /// Movie filmography as ready-to-render `SearchResult` rows, owned movies
    /// tagged from the Radarr library. Popularity-desc, year-desc — the same
    /// ordering the chat credits tools use (PersonRelevance refines this later).
    static func movieFilmography(personId: Int, tmdbKey key: String, radarrConfig: ServiceConfig) async -> [SearchResult] {
        if DemoMode.isActive { return DemoMocks.personMovies(personId: personId) }
        guard !key.isEmpty, let credits = try? await TMDBClient(apiKey: key).personMovieCredits(personId: personId) else { return [] }
        let libraryMap = await ArrLibraryMaps.radarrByTMDBId(config: radarrConfig)
        let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
        return TMDBSearchMapping.movies(PersonCreditMerge.byPopularity(merged.credits), libraryMap: libraryMap, roles: merged.roles)
    }

    /// TV filmography, structurally identical to the movie path: TMDB credits
    /// in, `SearchResult`s out, owned rows tagged from a library map keyed by
    /// TMDB id. The tvdbId a row eventually needs is resolved lazily, on tap,
    /// by `SeriesIdentityResolver` — never here, so a 100-title filmography
    /// costs one credits call and no per-row requests.
    static func seriesFilmography(personId: Int, tmdbKey key: String, sonarrConfig: ServiceConfig) async -> [SearchResult] {
        if DemoMode.isActive { return DemoMocks.personSeries(personId: personId) }
        guard !key.isEmpty, let credits = try? await TMDBClient(apiKey: key).personTVCredits(personId: personId) else { return [] }
        // Sonarr ships TMDB's series id on the library resource, so
        // ownership is an id match off the shared `LibraryIndex`
        // snapshot. This replaced a normalized title + year join, which
        // could tag a same-titled show as the one you own — and which
        // fetched the whole Sonarr library itself, bypassing the index.
        let libraryMap = await ArrLibraryMaps.sonarrByTMDBId(config: sonarrConfig)
        let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
        let rows = TMDBSearchMapping.series(
            PersonCreditMerge.byPopularity(merged.credits),
            libraryMap: libraryMap, roles: merged.roles)
        // Owned rows drill straight into a library record, bypassing
        // `SeriesIdentityResolver` and its log — so the pairing is
        // recorded here instead. Same question as everywhere else in this
        // flow: which show, by id, not by how the poster looks. Only the
        // owned ones (a handful per person), never the whole filmography.
        // `.notice` for the same reason as `SeriesIdentityResolver`: info
        // level is memory-only, so it can't be read back after the fact.
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
