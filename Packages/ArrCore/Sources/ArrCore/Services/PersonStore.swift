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
        if let hit = cache.movies[personId] { touch(personId); return hit }
        if let running = movieTasks[personId] { return await running.value }
        let task = Task<[SearchResult], Never> {
            guard !key.isEmpty else { return [] }
            guard let credits = try? await TMDBClient(apiKey: key).personMovieCredits(personId: personId) else { return [] }
            let libraryMap = await ArrLibraryMaps.radarrByTMDBId(config: radarrConfig)
            return TMDBSearchMapping.movies(Self.byPopularity(credits), libraryMap: libraryMap)
        }
        movieTasks[personId] = task
        let value = await task.value
        movieTasks[personId] = nil
        if !value.isEmpty { cache.movies[personId] = value; touch(personId); trim() }
        return value
    }

    /// TV filmography. Series can't be library-tagged from TMDB tv ids (they're
    /// not tvdb ids), so rows stay add-flow; the row resolves its tvdbId lazily
    /// on tap.
    public func seriesFilmography(personId: Int, tmdbKey key: String) async -> [SearchResult] {
        if let hit = cache.series[personId] { touch(personId); return hit }
        if let running = seriesTasks[personId] { return await running.value }
        let task = Task<[SearchResult], Never> {
            guard !key.isEmpty else { return [] }
            guard let credits = try? await TMDBClient(apiKey: key).personTVCredits(personId: personId) else { return [] }
            // TMDB tv_credits list one entry per role/appearance, so a recurring
            // or guest actor shows the SAME series many times (Seth Rogen ×104
            // Simpsons episodes). Collapse to one row per series id.
            return TMDBSearchMapping.series(Self.byPopularity(Self.dedupedById(credits)))
        }
        seriesTasks[personId] = task
        let value = await task.value
        seriesTasks[personId] = nil
        if !value.isEmpty { cache.series[personId] = value; touch(personId); trim() }
        return value
    }

    // MARK: - Helpers

    private static func byPopularity(_ movies: [TMDBMovieSummary]) -> [TMDBMovieSummary] {
        movies.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0, rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
    }
    /// One entry per series id (keeping the first — TMDB lists the primary
    /// billing first). Fixes recurring/guest actors showing a series once per
    /// episode.
    private static func dedupedById(_ shows: [TMDBTVSummary]) -> [TMDBTVSummary] {
        var seen = Set<Int>()
        return shows.filter { seen.insert($0.id).inserted }
    }

    private static func byPopularity(_ shows: [TMDBTVSummary]) -> [TMDBTVSummary] {
        shows.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0, rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
    }

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
