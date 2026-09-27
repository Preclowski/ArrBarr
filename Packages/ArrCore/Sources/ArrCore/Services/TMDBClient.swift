import Foundation
import MediaKit

nonisolated public enum TMDBDepartment {
    public static let acting = "Acting"
    public static let directing = "Directing"
    /// The crew `job` (not department) that means "this person directed it".
    /// The Directing department is much wider than this — assistant directors,
    /// script supervisors and the rest live there too — so the strip matches
    /// jobs, not the department.
    public static let directorJob = "Director"
    public static let coDirectorJob = "Co-Director"
}

// MARK: - Genre maps
//
// TMDB exposes /genre/movie/list and /genre/tv/list but those values are
// stable across decades — embedding them avoids an extra round-trip per
// session and lets the LLM pick a genre by name without a setup tool call.

nonisolated public enum TMDBGenres {
    public static let movie: [String: Int] = [
        "action": 28, "adventure": 12, "animation": 16, "comedy": 35,
        "crime": 80, "documentary": 99, "drama": 18, "family": 10751,
        "fantasy": 14, "history": 36, "horror": 27, "music": 10402,
        "mystery": 9648, "romance": 10749, "science fiction": 878,
        "sci-fi": 878, "tv movie": 10770, "thriller": 53, "war": 10752,
        "western": 37,
    ]
    public static let tv: [String: Int] = [
        "action & adventure": 10759, "action": 10759, "adventure": 10759,
        "animation": 16, "comedy": 35, "crime": 80, "documentary": 99,
        "drama": 18, "family": 10751, "kids": 10762, "mystery": 9648,
        "news": 10763, "reality": 10764,
        "sci-fi & fantasy": 10765, "sci-fi": 10765, "fantasy": 10765,
        "soap": 10766, "talk": 10767, "war & politics": 10768,
        "western": 37,
    ]

    /// Resolve a free-text genre token (case-insensitive). Returns nil for
    /// unknown tokens — caller should skip the filter rather than 0-out it.
    public static func movieId(for token: String) -> Int? {
        movie[token.lowercased()]
    }
    public static func tvId(for token: String) -> Int? {
        tv[token.lowercased()]
    }

    /// Reverse map for the "+ result card" hero — TMDB discover/credits
    /// returns numeric `genre_ids`; the SearchResult model carries the
    /// display name strings the SearchAddPanel renders as chips. We pick
    /// the first matching name (the maps have aliases that all map to the
    /// same id — e.g. "sci-fi" and "science fiction" both = 878).
    public static func movieName(for id: Int) -> String? {
        movie.first { $0.value == id }?.key.capitalized
    }
    public static func tvName(for id: Int) -> String? {
        tv.first { $0.value == id }?.key.capitalized
    }

    public static func movieNames(for ids: [Int]) -> [String] {
        ids.compactMap(movieName(for:))
    }
    public static func tvNames(for ids: [Int]) -> [String] {
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
    /// The one clip worth opening, or nil. Ranked rather than filtered: a
    /// title with only an unofficial teaser should still get a play button.
    /// YouTube-only because that's the only site we can hand to the OS.
    static func bestTrailerKey(_ videos: [TMDBVideo]) -> String? {
        let youTube = videos.filter { ($0.site ?? "YouTube") == "YouTube" && !$0.key.isEmpty }
        func rank(_ v: TMDBVideo) -> Int {
            switch (v.type, v.official ?? false) {
            case ("Trailer", true):  return 0
            case ("Trailer", false): return 1
            case ("Teaser", true):   return 2
            case ("Teaser", false):  return 3
            default:                 return 4
            }
        }
        // `min(by:)` keeps TMDB's own order inside a rank: its first entry is the one the site features.
        return youTube.min { rank($0) < rank($1) }?.key
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

/// TMDB through MediaKit, the key resolved per instance; results are MediaKit's records.
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
        return (gateway, TMDBService(instance: instance, capabilities: gateway.kit.capabilities))
    }

    private func read<V>(policy: ReadPolicy = .cacheFirst, _ make: (TMDBService) -> Resource<V>) async throws -> V {
        let (gateway, service) = try await context()
        return try await gateway.store.read(make(service), policy: policy).value
    }

    public func testConnection() async throws { _ = try await read(policy: .mustRevalidate) { $0.configuration() } }
    public func searchPerson(query: String) async throws -> [TMDBPerson] { try await read { $0.searchPerson(query: query) }.results }
    public func movieCredits(movieId: Int) async throws -> TMDBCredits { try await read { $0.movieCredits(id: movieId) } }
    public func tvCredits(tvId: Int) async throws -> TMDBCredits { try await read { $0.tvCredits(id: tvId) } }

    /// One episode's TMDB score. `nil` when the episode is unrated (TMDB sends
    /// `0` for that, which is not a rating).
    public func episodeRating(tvId: Int, season: Int, episode: Int) async throws -> (value: Double, votes: Int)? {
        let record = try await read { $0.tvEpisode(id: tvId, season: season, episode: episode) }
        guard let value = record.voteAverage, value > 0 else { return nil }
        return (value, record.voteCount ?? 0)
    }
    public func movieDetails(movieId: Int) async throws -> TMDBDetails { try await read { $0.movie(id: movieId) } }
    public func tvDetails(tvId: Int) async throws -> TMDBDetails { try await read { $0.tv(id: tvId) } }
    public func tvCreators(tvId: Int) async throws -> [TMDBPerson] { try await tvDetails(tvId: tvId).createdBy ?? [] }

    public func tvIdFromTVDB(_ tvdbId: Int) async throws -> Int? { try await read { $0.find(tvdbID: tvdbId) }.tvResults.first?.id }

    public func tvdbIdFromTVId(_ tvId: Int) async throws -> Int? {
        let ids = try await read { $0.tvExternalIDs(id: tvId) }
        guard let tvdb = ids.tvdbId, tvdb > 0 else { return nil }
        return tvdb
    }

    /// An empty biography in the user's language falls back to the English one.
    public func personDetails(personId: Int) async throws -> TMDBPersonDetails {
        let details = try await read { $0.person(id: personId) }
        guard details.biography?.isEmpty ?? true,
              let english = try? await read({ $0.person(id: personId, language: "en-US") }),
              !(english.biography?.isEmpty ?? true) else { return details }
        return english
    }

    public func personMovieCredits(personId: Int) async throws -> TMDBPersonCredits<TMDBMovieSummary> { try await read { $0.personMovieCredits(id: personId) } }
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

    /// Theatrical releases of the last six weeks, most popular first — what a
    /// model cannot know past its training cutoff. With a region the dates are
    /// that country's (a film opens in Warsaw weeks after LA); re-releases of
    /// old films stay out either way.
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

    /// Series in the middle of a fresh season: an episode within the last two
    /// weeks or the next one, from a season that began at most 90 days ago.
    /// "An episode this week" alone is every soap, talk show and 30-year-old
    /// anime.
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
                    let details = try? await self.tvDetails(tvId: show.id)
                    return details?.isFreshSeason(around: date) == true ? show.id : nil
                }
            }
            var ids = Set<Int>()
            for await id in group { if let id { ids.insert(id) } }
            return ids
        }
        return airing.filter { fresh.contains($0.id) }
    }

    private func twoPages<T>(_ fetch: @escaping @Sendable (Int) async throws -> [T]) async throws -> [T] where T: Sendable {
        async let first = fetch(1)
        async let second = try? fetch(2)
        return try await first + (await second ?? [])
    }

    private static func day(_ date: Date, offset days: Int) -> String {
        date.addingTimeInterval(TimeInterval(days) * 86_400).formatted(.iso8601.year().month().day())
    }

    public func recommendedMovies(movieId: Int, page: Int = 1) async throws -> [TMDBMovieSummary] {
        try await read { $0.movieRecommendations(id: movieId, page: page) }.results
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

    public static func imageURL(path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
