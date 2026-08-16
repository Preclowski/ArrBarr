import Foundation

/// The single owner of TMDB people data — biography detail and filmography —
/// shared by the person view and (later) the cast-head tooltip.
///
/// Every facet is fetched lazily and independently: opening the view fetches
/// the bio + movie credits; the series tab fetches tv credits only when shown.
/// Concurrent requests for the same (person, facet) coalesce into one network
/// call, so a tooltip hover and a view push don't double-fetch. Results are
/// held in a small session-lifetime LRU — headshots ride `PosterStore`, so
/// nothing here touches disk.
@MainActor
public final class PersonStore {
    public static let shared = PersonStore()
    private init() {}

    private struct Cache {
        var details: [Int: TMDBPersonDetails] = [:]
        var movies: [Int: [SearchResult]] = [:]
        var series: [Int: [SearchResult]] = [:]
    }
    private var cache = Cache()
    private var lru: [Int] = []
    private let capacity = 30

    private var detailTasks: [Int: Task<TMDBPersonDetails?, Never>] = [:]
    private var movieTasks: [Int: Task<[SearchResult], Never>] = [:]
    private var seriesTasks: [Int: Task<[SearchResult], Never>] = [:]

    // MARK: - Public API

    /// Biography / age / birthplace / external ids. nil without a TMDB key or
    /// on a failed lookup.
    public func details(personId: Int, tmdbKey key: String) async -> TMDBPersonDetails? {
        if DemoMode.isActive { return DemoMocks.personDetails(personId: personId) }
        if let hit = cache.details[personId] { touch(personId); return hit }
        if let running = detailTasks[personId] { return await running.value }
        let task = Task<TMDBPersonDetails?, Never> {
            guard !key.isEmpty else { return nil }
            return try? await TMDBClient(apiKey: key).personDetails(personId: personId)
        }
        detailTasks[personId] = task
        let value = await task.value
        detailTasks[personId] = nil
        if let value { cache.details[personId] = value; touch(personId); trim() }
        return value
    }

    /// Movie filmography as ready-to-render `SearchResult` rows, owned movies
    /// tagged from the Radarr library. Popularity-desc, year-desc — the same
    /// ordering the chat credits tools use (PersonRelevance refines this later).
    public func movieFilmography(personId: Int, tmdbKey key: String, radarrConfig: ServiceConfig) async -> [SearchResult] {
        if DemoMode.isActive { return DemoMocks.personMovies(personId: personId) }
        if let hit = cache.movies[personId] { touch(personId); return hit }
        if let running = movieTasks[personId] { return await running.value }
        let task = Task<[SearchResult], Never> {
            guard !key.isEmpty else { return [] }
            guard let credits = try? await TMDBClient(apiKey: key).personMovieCredits(personId: personId) else { return [] }
            let libraryMap = await ArrLibraryMaps.radarrByTMDBId(config: radarrConfig)
            let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
            let unique = PersonCreditMerge.byPopularity(merged.credits)
            return TMDBSearchMapping.movies(unique, libraryMap: libraryMap, roles: merged.roles)
        }
        movieTasks[personId] = task
        let value = await task.value
        movieTasks[personId] = nil
        if !value.isEmpty { cache.movies[personId] = value; touch(personId); trim() }
        return value
    }

    /// TV filmography, structurally identical to the movie path: TMDB credits
    /// in, `SearchResult`s out, owned rows tagged from a library map keyed by
    /// TMDB id. The tvdbId a row eventually needs is resolved lazily, on tap,
    /// by `SeriesIdentityResolver` — never here, so a 100-title filmography
    /// costs one credits call and no per-row requests.
    public func seriesFilmography(personId: Int, tmdbKey key: String, sonarrConfig: ServiceConfig) async -> [SearchResult] {
        if DemoMode.isActive { return DemoMocks.personSeries(personId: personId) }
        if let hit = cache.series[personId] { touch(personId); return hit }
        if let running = seriesTasks[personId] { return await running.value }
        let task = Task<[SearchResult], Never> {
            guard !key.isEmpty else { return [] }
            guard let credits = try? await TMDBClient(apiKey: key).personTVCredits(personId: personId) else { return [] }
            // Sonarr ships TMDB's series id on the library resource, so
            // ownership is an id match off the shared `LibraryIndex`
            // snapshot. This replaced a normalized title + year join, which
            // could tag a same-titled show as the one you own — and which
            // fetched the whole Sonarr library itself, bypassing the index.
            let libraryMap = await ArrLibraryMaps.sonarrByTMDBId(config: sonarrConfig)
            let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
            return TMDBSearchMapping.series(
                PersonCreditMerge.byPopularity(merged.credits),
                libraryMap: libraryMap, roles: merged.roles)
        }
        seriesTasks[personId] = task
        let value = await task.value
        seriesTasks[personId] = nil
        if !value.isEmpty { cache.series[personId] = value; touch(personId); trim() }
        return value
    }

    // MARK: - Helpers

    private func touch(_ id: Int) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }
    private func trim() {
        while lru.count > capacity {
            let evicted = lru.removeFirst()
            cache.details[evicted] = nil
            cache.movies[evicted] = nil
            cache.series[evicted] = nil
        }
    }
}
