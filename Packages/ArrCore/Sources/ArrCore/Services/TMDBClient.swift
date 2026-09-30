import os
import Foundation
import MediaKit

nonisolated enum TMDBDepartment {
    static let acting = "Acting"
    static let directing = "Directing"
    /// The crew `job` meaning "directed it"; the Directing department also holds
    /// assistant directors and script supervisors, so match jobs, not the department.
    static let directorJob = "Director"
    static let coDirectorJob = "Co-Director"
}

// MARK: - Genre maps
// TMDB's genre ids are stable for decades; embedding them saves a round-trip
// and lets the LLM pick a genre by name.

nonisolated enum TMDBGenres {
    static let movie: [String: Int] = [
        "action": 28, "adventure": 12, "animation": 16, "comedy": 35,
        "crime": 80, "documentary": 99, "drama": 18, "family": 10751,
        "fantasy": 14, "history": 36, "horror": 27, "music": 10402,
        "mystery": 9648, "romance": 10749, "science fiction": 878,
        "sci-fi": 878, "tv movie": 10770, "thriller": 53, "war": 10752,
        "western": 37,
    ]
    static let tv: [String: Int] = [
        "action & adventure": 10759, "action": 10759, "adventure": 10759,
        "animation": 16, "comedy": 35, "crime": 80, "documentary": 99,
        "drama": 18, "family": 10751, "kids": 10762, "mystery": 9648,
        "news": 10763, "reality": 10764,
        "sci-fi & fantasy": 10765, "sci-fi": 10765, "fantasy": 10765,
        "soap": 10766, "talk": 10767, "war & politics": 10768,
        "western": 37,
    ]

    /// Case-insensitive; nil for unknown tokens — skip the filter rather than 0-out it.
    static func movieId(for token: String) -> Int? {
        movie[token.lowercased()]
    }
    static func tvId(for token: String) -> Int? {
        tv[token.lowercased()]
    }

    /// Aliases share an id ("sci-fi" and "science fiction" = 878); the first matching name wins.
    static func movieName(for id: Int) -> String? {
        movie.first { $0.value == id }?.key.capitalized
    }
    static func tvName(for id: Int) -> String? {
        tv.first { $0.value == id }?.key.capitalized
    }

    static func movieNames(for ids: [Int]) -> [String] {
        ids.compactMap(movieName(for:))
    }
    static func tvNames(for ids: [Int]) -> [String] {
        ids.compactMap(tvName(for:))
    }
}

// MARK: - Derived values on MediaKit's TMDB records

nonisolated public extension TMDBPerson {
    var profileURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }
    var isDirector: Bool { knownForDepartment == TMDBDepartment.directing }
    /// Movies credit one `character`; TV aggregate credits list them per stint.
    var characterName: String? {
        if let character, !character.isEmpty { return character }
        return roles?.first(where: { !($0.character ?? "").isEmpty })?.character
    }
}

nonisolated public extension TMDBPersonDetails {
    var profileURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }
    var imdbURL: URL? {
        guard let imdbId, !imdbId.isEmpty else { return nil }
        return URL(string: "https://www.imdb.com/name/\(imdbId)/")
    }
    var tmdbURL: URL? { URL(string: "https://www.themoviedb.org/person/\(id)") }

    var age: Int? {
        guard let birthday, let born = Self.day(birthday) else { return nil }
        let end = deathday.flatMap(Self.day) ?? Date()
        return Calendar.current.dateComponents([.year], from: born, to: end).year
    }

    private static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}

nonisolated public extension TMDBMovieSummary {
    var year: Int? { releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
}

nonisolated public extension TMDBTVSummary {
    var year: Int? { firstAirDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
}

nonisolated public extension TMDBVideo {
    /// Ranked rather than filtered: a title with only an unofficial teaser still gets
    /// a play button. YouTube-only because that's the only embed we can play.
    static func rankedYouTube(_ videos: [TMDBVideo]) -> [TMDBVideo] {
        func rank(_ v: TMDBVideo) -> Int {
            switch (v.type, v.official ?? false) {
            case ("Trailer", true):  return 0
            case ("Trailer", false): return 1
            case ("Teaser", true):   return 2
            case ("Teaser", false):  return 3
            default:                 return 4
            }
        }
        // Index tiebreak keeps TMDB's order within a rank: its first entry is the one the site features.
        return videos.enumerated()
            .filter { ($0.element.site ?? "YouTube") == "YouTube" && !$0.element.key.isEmpty }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

nonisolated public extension TMDBDetails {
    /// An episode within two weeks back or one ahead, from a season that premiered at most 90 days ago.
    func isFreshSeason(around date: Date) -> Bool {
        func day(_ offset: Int) -> String {
            date.addingTimeInterval(TimeInterval(offset) * 86_400).formatted(.iso8601.year().month().day())
        }
        let current = [lastEpisodeToAir, nextEpisodeToAir].compactMap { $0 }.first { episode in
            guard let aired = episode.airDate else { return false }
            return aired >= day(-14) && aired <= day(7)
        }
        guard let number = current?.seasonNumber,
              let premiere = seasons?.first(where: { $0.seasonNumber == number })?.airDate else { return false }
        return premiere >= day(-90) && premiere <= day(7)
    }
}

// MARK: - Client

nonisolated public struct TMDBClient: Sendable {
    public let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    public var isConfigured: Bool { !apiKey.isEmpty }

    private func context() async throws -> (ServiceGateway, TMDBService) {
        guard isConfigured else { throw MediaKitError.notConfigured(InstanceID(.tmdb)) }
        let gateway = await ServiceGateway.resolve()
        let instance = await gateway.adopt(tmdbKey: apiKey)
        await gateway.ready()
        guard gateway.isConfigured(instance) else { throw MediaKitError.notConfigured(instance) }
        return (gateway, TMDBService(instance: instance))
    }

    private func read<V>(policy: ReadPolicy = .cacheFirst, _ make: (TMDBService) -> Resource<V>) async throws -> V {
        let (gateway, service) = try await context()
        return try await gateway.store.read(make(service), policy: policy).value
    }

    public func testConnection() async throws { _ = try await read(policy: .mustRevalidate) { $0.configuration() } }
    public func searchPerson(query: String) async throws -> [TMDBPerson] { try await read { $0.searchPerson(query: query) }.results }
    public func movieCredits(movieId: Int) async throws -> TMDBCredits { try await read { $0.movieCredits(id: movieId) } }
    public func tvCredits(tvId: Int) async throws -> TMDBCredits { try await read { $0.tvCredits(id: tvId) } }

    /// `nil` when unrated — TMDB sends `0` for that, which is not a rating.
    public func episodeRating(tvId: Int, season: Int, episode: Int) async throws -> (value: Double, votes: Int)? {
        let record = try await read { $0.tvEpisode(id: tvId, season: season, episode: episode) }
        guard let value = record.voteAverage, value > 0 else { return nil }
        return (value, record.voteCount ?? 0)
    }
    public func movieDetails(movieId: Int, language: String? = nil) async throws -> TMDBDetails { try await read { $0.movie(id: movieId, language: language) } }
    public func tvDetails(tvId: Int, language: String? = nil) async throws -> TMDBDetails { try await read { $0.tv(id: tvId, language: language) } }
    public func tvCreators(tvId: Int) async throws -> [TMDBPerson] { try await tvDetails(tvId: tvId).createdBy ?? [] }

    public func tvIdFromTVDB(_ tvdbId: Int) async throws -> Int? { try await read { $0.find(tvdbID: tvdbId) }.tvResults.first?.id }

    /// A series' TMDB id: the one the arr shipped, else resolved from its TVDB id.
    func seriesId(tmdbId: Int?, tvdbId: Int?) async -> Int? {
        if let tmdbId, tmdbId > 0 { return tmdbId }
        guard let tvdbId, tvdbId > 0 else { return nil }
        return await Logger.extras.attempt("tvdb → tmdb series id") { try await tvIdFromTVDB(tvdbId) } ?? nil
    }

    public func tvdbIdFromTVId(_ tvId: Int) async throws -> Int? {
        let ids = try await read { $0.tvExternalIDs(id: tvId) }
        guard let tvdb = ids.tvdbId, tvdb > 0 else { return nil }
        return tvdb
    }

    /// An empty biography in the user's language falls back to the English one.
    public func personDetails(personId: Int) async throws -> TMDBPersonDetails {
        let details = try await read { $0.person(id: personId) }
        guard details.biography?.isEmpty ?? true,
              let english = await Logger.extras.attempt("english biography", { try await read { $0.person(id: personId, language: "en-US") } }),
              !(english.biography?.isEmpty ?? true) else { return details }
        return english
    }

    public func personMovieCredits(personId: Int, language: String? = nil) async throws -> TMDBPersonCredits<TMDBMovieSummary> {
        try await read { $0.personMovieCredits(id: personId, language: language) }
    }
    public func personTVCredits(personId: Int) async throws -> TMDBPersonCredits<TMDBTVSummary> { try await read { $0.personTVCredits(id: personId) } }

    public func discoverMovies(genreIds: [Int] = [], startYear: Int? = nil, endYear: Int? = nil, sortBy: String = "popularity.desc", minVoteCount: Int = 50) async throws -> [TMDBMovieSummary] {
        var extra: [(String, String)] = []
        if !genreIds.isEmpty { extra.append(("with_genres", genreIds.map(String.init).joined(separator: ","))) }
        if let y = startYear { extra.append(("primary_release_date.gte", "\(y)-01-01")) }
        if let y = endYear { extra.append(("primary_release_date.lte", "\(y)-12-31")) }
        return try await read { $0.discoverMovies(sort: sortBy, minVotes: minVoteCount, extra: extra) }.results
    }

    public func discoverTV(genreIds: [Int] = [], startYear: Int? = nil, endYear: Int? = nil, sortBy: String = "popularity.desc", minVoteCount: Int = 20) async throws -> [TMDBTVSummary] {
        var extra: [(String, String)] = []
        if !genreIds.isEmpty { extra.append(("with_genres", genreIds.map(String.init).joined(separator: ","))) }
        if let y = startYear { extra.append(("first_air_date.gte", "\(y)-01-01")) }
        if let y = endYear { extra.append(("first_air_date.lte", "\(y)-12-31")) }
        return try await read { $0.discoverTV(sort: sortBy, minVotes: minVoteCount, extra: extra) }.results
    }

    /// Theatrical releases of the last six weeks, most popular first — what a model cannot
    /// know past its cutoff. With a region the dates are that country's.
    public func moviesInCinemas(region: String?, around date: Date = Date()) async throws -> [TMDBMovieSummary] {
        let dateField = region == nil ? "primary_release_date" : "release_date"
        var extra = [("\(dateField).gte", Self.day(date, offset: -42)),
                     ("\(dateField).lte", Self.day(date, offset: 7)),
                     ("with_release_type", "2|3")]
        if let region {
            extra += [("region", region), ("primary_release_date.gte", Self.day(date, offset: -365))]
        }
        let query = extra
        return try await twoPages { page in
            try await self.read { $0.discoverMovies(minVotes: 10, page: page, extra: query) }.results
        }
    }

    /// Series mid fresh season. "An episode this week" alone would match every soap,
    /// talk show and 30-year-old anime.
    public func seriesOnAir(around date: Date = Date()) async throws -> [TMDBTVSummary] {
        let extra = [("air_date.gte", Self.day(date, offset: -14)),
                     ("air_date.lte", Self.day(date, offset: 7)),
                     // Kids, news, reality, soap, talk.
                     ("without_genres", "10762,10763,10764,10766,10767")]
        let airing = try await twoPages { page in
            try await self.read { $0.discoverTV(minVotes: 10, page: page, extra: extra) }.results
        }
        let fresh = await withTaskGroup(of: Int?.self) { group in
            for show in airing {
                group.addTask {
                    let details = await Logger.extras.attempt("fresh-season check") { try await self.tvDetails(tvId: show.id) }
                    return details?.isFreshSeason(around: date) == true ? show.id : nil
                }
            }
            var ids = Set<Int>()
            for await id in group { if let id { ids.insert(id) } }
            return ids
        }
        return airing.filter { fresh.contains($0.id) }
    }

    /// Most popular first, `pages` deep; a title that moved between pages mid-fetch shows once.
    public func popularMovies(pages: Int = 3) async throws -> [TMDBMovieSummary] {
        let all = try await firstPages(pages) { page in
            try await self.read { $0.discoverMovies(page: page) }.results
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// Without kids, news, reality, soap and talk shows, which otherwise crowd the top.
    public func popularSeries(pages: Int = 3) async throws -> [TMDBTVSummary] {
        let extra = [("without_genres", "10762,10763,10764,10766,10767")]
        let all = try await firstPages(pages) { page in
            try await self.read { $0.discoverTV(minVotes: 20, page: page, extra: extra) }.results
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// Fetched together, returned in page order. Only the first page must answer.
    private func firstPages<T>(_ count: Int, _ fetch: @escaping @Sendable (Int) async throws -> [T]) async throws -> [T] where T: Sendable {
        async let first = fetch(1)
        let rest = await withTaskGroup(of: (Int, [T]).self) { group in
            for page in stride(from: 2, through: count, by: 1) {
                group.addTask { (page, (try? await fetch(page)) ?? []) }
            }
            var pages: [Int: [T]] = [:]
            for await (page, items) in group { pages[page] = items }
            return pages.keys.sorted().flatMap { pages[$0] ?? [] }
        }
        return try await first + rest
    }

    private func twoPages<T>(_ fetch: @escaping @Sendable (Int) async throws -> [T]) async throws -> [T] where T: Sendable {
        async let first = fetch(1)
        async let second = try? fetch(2)
        return try await first + (await second ?? [])
    }

    private static func day(_ date: Date, offset days: Int) -> String {
        date.addingTimeInterval(TimeInterval(days) * 86_400).formatted(.iso8601.year().month().day())
    }

    public func recommendedMovies(movieId: Int, page: Int = 1, language: String? = nil) async throws -> [TMDBMovieSummary] {
        try await read { $0.movieRecommendations(id: movieId, page: page, language: language) }.results
    }

    public func recommendedTV(seriesId: Int, page: Int = 1) async throws -> [TMDBTVSummary] {
        try await read { $0.tvRecommendations(id: seriesId, page: page) }.results
    }

    public func movieVideos(movieId: Int) async throws -> [TMDBVideo] { try await read { $0.movieVideos(id: movieId) }.results }
    public func tvVideos(tvId: Int) async throws -> [TMDBVideo] { try await read { $0.tvVideos(id: tvId) }.results }

    public func movieIMDbId(movieId: Int) async throws -> String? {
        let id = try await movieDetails(movieId: movieId).imdbId
        return (id?.isEmpty == false) ? id : nil
    }

    public func movieCountries(movieId: Int) async throws -> [String] { try await movieDetails(movieId: movieId).countryCodes(preferOrigin: false) }
    public func tvCountries(tvId: Int) async throws -> [String] { try await tvDetails(tvId: tvId).countryCodes(preferOrigin: true) }

    public static func imageURL(path: String?, size: String = "w342") -> URL? { TMDBService.imageURL(path: path, size: size) }
}
