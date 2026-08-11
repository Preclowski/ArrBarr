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

    /// TV filmography. Series can't be library-tagged from TMDB tv ids (they're
    /// not tvdb ids), so rows stay add-flow; the row resolves its tvdbId lazily
    /// on tap.
    public func seriesFilmography(personId: Int, tmdbKey key: String, sonarrConfig: ServiceConfig) async -> [SearchResult] {
        if let hit = cache.series[personId] { touch(personId); return hit }
        if let running = seriesTasks[personId] { return await running.value }
        let task = Task<[SearchResult], Never> {
            guard !key.isEmpty else { return [] }
            guard let credits = try? await TMDBClient(apiKey: key).personTVCredits(personId: personId) else { return [] }
            let merged = PersonCreditMerge.merge(cast: credits.cast, crew: credits.crew ?? [])
            let rows = TMDBSearchMapping.series(PersonCreditMerge.byPopularity(merged.credits), roles: merged.roles)
            // Series carry a TMDB tv id, not a tvdb id, so the usual id-based
            // library map can't tag them. Match on normalized title + year
            // against the Sonarr library instead — a local join, no per-row
            // network calls — so an owned series (e.g. The Simpsons) drills into
            // its detail instead of offering to add a duplicate.
            let owned = await Self.sonarrOwnershipByTitle(config: sonarrConfig)
            guard !owned.isEmpty else { return rows }
            return rows.map { r in
                if let arrId = owned[Self.titleYearKey(title: r.title, year: r.year)] {
                    return r.withInLibraryArrId(arrId)
                }
                return r
            }
        }
        seriesTasks[personId] = task
        let value = await task.value
        seriesTasks[personId] = nil
        if !value.isEmpty { cache.series[personId] = value; touch(personId); trim() }
        return value
    }

    // MARK: - Helpers

    /// `(normalized title, year) → Sonarr series id` for the whole library, so
    /// TMDB series (which have no tvdb id) can still be tagged as owned by a
    /// local title/year join.
    private static func sonarrOwnershipByTitle(config: ServiceConfig) async -> [String: Int] {
        guard config.isConfigured else { return [:] }
        guard let library = try? await SonarrClient(config: config).fetchAllSeries() else { return [:] }
        var map: [String: Int] = [:]
        for rec in library {
            guard let title = rec.title, let arrId = rec.id else { continue }
            map[titleYearKey(title: title, year: rec.year)] = arrId
        }
        return map
    }

    private static func titleYearKey(title: String, year: Int?) -> String {
        "\(SearchRelevance.normalize(title))|\(year ?? 0)"
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
