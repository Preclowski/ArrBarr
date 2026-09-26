import Foundation
import MediaKit

// MARK: - Wire types
//
// TMDB v3 API. Only fields we actually consume are decoded — the wire payload
// is much richer (production_companies, runtime, original_language, …) but
// pulling everything makes the codable surface fragile when TMDB tweaks schema.

/// TMDB's fixed English department/job tokens. They arrive verbatim on every
/// payload regardless of the request language, so matching them is string
/// matching against constants — never against a localized label.
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

nonisolated public struct TMDBPerson: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let knownForDepartment: String?
    public let profilePath: String?
    /// Ranking signal for "which person did the user mean" — TMDB's own
    /// relevance/fame score. nil on payloads that don't include it.
    public let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, popularity
        case knownForDepartment = "known_for_department"
        case profilePath = "profile_path"
    }

    public var profileURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }

    /// Whether TMDB files this person under directing. Directors are a
    /// first-class person type in the app — they rank alongside actors and get
    /// their own "Directed by" wording — so the check has one home.
    public var isDirector: Bool { knownForDepartment == TMDBDepartment.directing }
}

/// `/person/{id}` — the biography-bearing detail record. Only the fields the
/// person view / tooltip render are decoded.
nonisolated public struct TMDBPersonDetails: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let biography: String?
    public let birthday: String?
    public let deathday: String?
    public let placeOfBirth: String?
    public let profilePath: String?
    public let imdbId: String?
    public let knownForDepartment: String?

    enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, deathday
        case placeOfBirth = "place_of_birth"
        case profilePath = "profile_path"
        case imdbId = "imdb_id"
        case knownForDepartment = "known_for_department"
    }

    public var profileURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }
    public var imdbURL: URL? {
        guard let imdbId, !imdbId.isEmpty else { return nil }
        return URL(string: "https://www.imdb.com/name/\(imdbId)/")
    }
    public var tmdbURL: URL? { URL(string: "https://www.themoviedb.org/person/\(id)") }

    /// Current age (or age at death), computed from `birthday`/`deathday`.
    public var age: Int? {
        guard let birthday, let born = Self.date(birthday) else { return nil }
        let end = deathday.flatMap(Self.date) ?? Date()
        return Calendar.current.dateComponents([.year], from: born, to: end).year
    }

    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}

nonisolated public struct TMDBPagedPeople: Codable, Sendable {
    public let results: [TMDBPerson]
}

nonisolated public struct TMDBMovieSummary: Codable, Sendable, Equatable {
    public let id: Int
    public let title: String
    public let releaseDate: String?
    public let posterPath: String?
    public let voteAverage: Double?
    public let voteCount: Int?
    public let popularity: Double?
    public let overview: String?
    public let genreIds: [Int]?
    public let character: String?   // present on credits responses
    public let department: String?  // crew credits only ("Directing"/"Writing"/…)

    enum CodingKeys: String, CodingKey {
        case id, title, overview, character, popularity, department
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
    }

    public var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

nonisolated public struct TMDBTVSummary: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let firstAirDate: String?
    public let posterPath: String?
    public let voteAverage: Double?
    public let voteCount: Int?
    public let popularity: Double?
    public let overview: String?
    public let genreIds: [Int]?
    public let character: String?
    public let department: String?  // crew credits only ("Directing"/"Writing"/…)

    enum CodingKeys: String, CodingKey {
        case id, name, overview, character, popularity, department
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
    }

    public var year: Int? {
        guard let firstAirDate, firstAirDate.count >= 4 else { return nil }
        return Int(firstAirDate.prefix(4))
    }
}

nonisolated public struct TMDBMovieCreditsResponse: Codable, Sendable {
    public let cast: [TMDBMovieSummary]
    public let crew: [TMDBMovieSummary]?
}

nonisolated public struct TMDBTVCreditsResponse: Codable, Sendable {
    public let cast: [TMDBTVSummary]
    public let crew: [TMDBTVSummary]?
}

// MARK: - Movie credits (cast + crew)

nonisolated public struct TMDBCredits: Codable, Sendable, Equatable {
    public let cast: [TMDBCreditPerson]
    public let crew: [TMDBCreditPerson]
}

nonisolated public struct TMDBCreditPerson: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let profilePath: String?
    /// For cast: the character name. For crew: nil. **Movies only** — the
    /// series endpoint is `/aggregate_credits`, which puts the character in
    /// `roles` instead and leaves this absent; read `characterName`, not this.
    public let character: String?
    /// `/tv/{id}/aggregate_credits`: one entry per part the person played,
    /// newest role first. A series regular has one; a soap actor has several.
    public let roles: [Role]?

    nonisolated public struct Role: Codable, Sendable, Equatable {
        public let character: String?
        public let episode_count: Int?
    }

    /// The part this person plays, whichever endpoint the credit came from.
    public var characterName: String? {
        if let character, !character.isEmpty { return character }
        return roles?.first(where: { !($0.character ?? "").isEmpty })?.character
    }
    /// For crew: the job (e.g., "Director"). For cast: nil.
    public let job: String?
    /// For crew: the department (e.g., "Directing"). For cast: nil.
    public let department: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character, roles, job, department
        case profilePath = "profile_path"
    }

    public var posterURL: URL? {
        TMDBClient.imageURL(path: profilePath, size: "w185")
    }
}

/// `/tv/{id}` → `created_by`. A series has no single director (episodes each
/// have their own), so the creator is the credit that plays the director's
/// role for a show. The entries carry the same id/name/profile fields as a
/// credit person, so they decode into the same type.
/// `/tv/{id}/season/{n}/episode/{n}` — the rating and nothing else.
/// `/movie/{id}` — just the external id.
nonisolated public struct TMDBMovieIDs: Codable, Sendable {
    public let imdbId: String?
}

nonisolated public struct TMDBEpisodeRating: Codable, Sendable {
    public let voteAverage: Double?
    public let voteCount: Int?
}

nonisolated public struct TMDBTVCreatedByResponse: Codable, Sendable {
    public let created_by: [TMDBCreditPerson]?
}

nonisolated public struct TMDBDiscoverMovieResponse: Codable, Sendable {
    public let results: [TMDBMovieSummary]
}

nonisolated public struct TMDBDiscoverTVResponse: Codable, Sendable {
    public let results: [TMDBTVSummary]
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

// MARK: - Client
//
/// One entry of TMDB's `/videos` — in practice always a YouTube clip; TMDB
/// hosts no video of its own, it only points at one.
nonisolated public struct TMDBVideo: Codable, Sendable, Equatable {
    public let key: String
    public let site: String?
    public let type: String?
    public let official: Bool?
    public let name: String?

    public init(key: String, site: String?, type: String?, official: Bool?, name: String? = nil) {
        self.key = key
        self.site = site
        self.type = type
        self.official = official
        self.name = name
    }

    /// The one clip worth opening, or nil. Ranked rather than filtered: a
    /// title with only an unofficial teaser should still get a play button —
    /// showing SOMETHING beats a chip that vanishes for half the library.
    /// YouTube-only because that's the only site we can hand to the OS.
    public static func bestTrailerKey(_ videos: [TMDBVideo]) -> String? {
        let youTube = videos.filter { ($0.site ?? "YouTube") == "YouTube" && !$0.key.isEmpty }
        func rank(_ v: TMDBVideo) -> Int {
            let official = v.official ?? false
            switch (v.type, official) {
            case ("Trailer", true):  return 0
            case ("Trailer", false): return 1
            case ("Teaser", true):   return 2
            case ("Teaser", false):  return 3
            default:                 return 4
            }
        }
        // `min(by:)` keeps TMDB's own order inside a rank — its first entry is
        // the one the site itself features.
        return youTube.min { rank($0) < rank($1) }?.key
    }
}

// Plain struct over URLSession — TMDB endpoints are stateless and don't
// need per-instance caching. Sendable so it can be passed across actors.

/// TMDB through MediaKit: the same methods and result types as before, the key resolved per instance.
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

    /// ArrCore's TMDB types spell their keys; MediaKit's rely on the snake-case decoder.
    private func read<T: Codable & Sendable, V>(_ type: T.Type, policy: ReadPolicy = .cacheFirst, decoder: JSONDecoder = WireCodec.decoder,
                                                _ make: (TMDBService) -> Resource<V>) async throws -> T {
        let (gateway, service) = try await context()
        let template = make(service)
        return try await gateway.store.read(Resource<T>.json(template.plan, tags: template.tags, freshness: template.freshness, decoder: decoder), policy: policy).value
    }

    public func testConnection() async throws { _ = try await read(MediaKit.TMDBConfiguration.self, policy: .mustRevalidate, decoder: WireCodec.snakeCaseDecoder) { $0.configuration() } }
    public func searchPerson(query: String) async throws -> [TMDBPerson] { try await read(TMDBPagedPeople.self) { $0.searchPerson(query: query) }.results }
    public func movieCredits(movieId: Int) async throws -> TMDBCredits { try await read(TMDBCredits.self) { $0.movieCredits(id: movieId) } }
    public func tvCredits(tvId: Int) async throws -> TMDBCredits { try await read(TMDBCredits.self) { $0.tvCredits(id: tvId) } }

    /// One episode's TMDB score. `nil` when the episode is unrated (TMDB sends
    /// `0` for that, which is not a rating).
    public func episodeRating(tvId: Int, season: Int, episode: Int) async throws -> (value: Double, votes: Int)? {
        let record = try await read(TMDBEpisodeRating.self, decoder: WireCodec.snakeCaseDecoder) {
            $0.tvEpisode(id: tvId, season: season, episode: episode)
        }
        guard let value = record.voteAverage, value > 0 else { return nil }
        return (value, record.voteCount ?? 0)
    }
    public func movieFacts(movieId: Int) async throws -> TMDBMovieFacts { try await read(TMDBMovieFacts.self, decoder: WireCodec.snakeCaseDecoder) { $0.movie(id: movieId) } }
    public func tvFacts(tvId: Int) async throws -> TMDBTVFacts { try await read(TMDBTVFacts.self, decoder: WireCodec.snakeCaseDecoder) { $0.tv(id: tvId) } }
    public func tvCreators(tvId: Int) async throws -> [TMDBCreditPerson] { try await read(TMDBTVCreatedByResponse.self) { $0.tv(id: tvId) }.created_by ?? [] }

    public func tvIdFromTVDB(_ tvdbId: Int) async throws -> Int? { try await read(MediaKit.TMDBFind.self, decoder: WireCodec.snakeCaseDecoder) { $0.find(tvdbID: tvdbId) }.tvResults.first?.id }

    public func tvdbIdFromTVId(_ tvId: Int) async throws -> Int? {
        let ids = try await read(MediaKit.TMDBExternalIDs.self, decoder: WireCodec.snakeCaseDecoder) { $0.tvExternalIDs(id: tvId) }
        guard let tvdb = ids.tvdbId, tvdb > 0 else { return nil }
        return tvdb
    }

    /// An empty biography in the user's language falls back to the English one.
    public func personDetails(personId: Int) async throws -> TMDBPersonDetails {
        let details = try await read(TMDBPersonDetails.self) { $0.person(id: personId) }
        if details.biography?.isEmpty ?? true {
            let (gateway, service) = try await context()
            var plan = service.person(id: personId).plan
            plan.query.append(.init("language", "en-US"))
            if let english = try? await gateway.store.read(Resource<TMDBPersonDetails>.json(plan, tags: [.identity(.tmdbPerson(personId))], freshness: .archival)).value,
               !(english.biography?.isEmpty ?? true) {
                return english
            }
        }
        return details
    }

    public func personMovieCredits(personId: Int) async throws -> TMDBMovieCreditsResponse { try await read(TMDBMovieCreditsResponse.self) { $0.personMovieCredits(id: personId) } }
    public func personTVCredits(personId: Int) async throws -> TMDBTVCreditsResponse { try await read(TMDBTVCreditsResponse.self) { $0.personTVCredits(id: personId) } }

    public func discoverMovies(genreIds: [Int] = [], startYear: Int? = nil, endYear: Int? = nil, sortBy: String = "popularity.desc", minVoteCount: Int = 50) async throws -> [TMDBMovieSummary] {
        var extra: [(String, String)] = []
        if !genreIds.isEmpty { extra.append(("with_genres", genreIds.map(String.init).joined(separator: ","))) }
        if let y = startYear { extra.append(("primary_release_date.gte", "\(y)-01-01")) }
        if let y = endYear { extra.append(("primary_release_date.lte", "\(y)-12-31")) }
        return try await read(TMDBDiscoverMovieResponse.self) { $0.discoverMovies(sort: sortBy, minVotes: minVoteCount, extra: extra) }.results
    }

    public func discoverTV(genreIds: [Int] = [], startYear: Int? = nil, endYear: Int? = nil, sortBy: String = "popularity.desc", minVoteCount: Int = 20) async throws -> [TMDBTVSummary] {
        var extra: [(String, String)] = []
        if !genreIds.isEmpty { extra.append(("with_genres", genreIds.map(String.init).joined(separator: ","))) }
        if let y = startYear { extra.append(("first_air_date.gte", "\(y)-01-01")) }
        if let y = endYear { extra.append(("first_air_date.lte", "\(y)-12-31")) }
        return try await read(TMDBDiscoverTVResponse.self) { $0.discoverTV(sort: sortBy, minVotes: minVoteCount, extra: extra) }.results
    }

    public func recommendedMovies(movieId: Int, page: Int = 1) async throws -> [TMDBMovieSummary] {
        try await read(TMDBDiscoverMovieResponse.self) { $0.movieRecommendations(id: movieId, page: page) }.results
    }

    public func recommendedTV(seriesId: Int, page: Int = 1) async throws -> [TMDBTVSummary] {
        try await read(TMDBDiscoverTVResponse.self) { $0.tvRecommendations(id: seriesId, page: page) }.results
    }

    public func movieVideos(movieId: Int) async throws -> [TMDBVideo] { try await read(VideoEnvelope.self) { $0.movieVideos(id: movieId) }.results }
    public func tvVideos(tvId: Int) async throws -> [TMDBVideo] { try await read(VideoEnvelope.self) { $0.tvVideos(id: tvId) }.results }
    nonisolated private struct VideoEnvelope: Codable, Sendable { let results: [TMDBVideo] }

    /// The film's IMDb id (`tt…`), off the same `/movie/{id}` payload the
    /// country line already reads — so when the detail view has been open this
    /// is a cache hit, and when it hasn't it is one archival request. TMDB
    /// rows (the Quiz deck, a person's filmography) carry no IMDb id of their
    /// own; without this their IMDb pill can only open a title search.
    public func movieIMDbId(movieId: Int) async throws -> String? {
        let id = try await read(TMDBMovieIDs.self, decoder: WireCodec.snakeCaseDecoder) { $0.movie(id: movieId) }.imdbId
        return (id?.isEmpty == false) ? id : nil
    }

    public func movieCountries(movieId: Int) async throws -> [String] {
        Self.codes(from: try await read(TMDBCountries.self) { $0.movie(id: movieId) }, preferOrigin: false)
    }

    public func tvCountries(tvId: Int) async throws -> [String] {
        Self.codes(from: try await read(TMDBCountries.self) { $0.tv(id: tvId) }, preferOrigin: true)
    }

    nonisolated private struct TMDBCountries: Codable, Sendable {
        nonisolated struct Country: Codable, Sendable { let iso_3166_1: String? }
        let production_countries: [Country]?
        let origin_country: [String]?
    }

    private static func codes(from resp: TMDBCountries, preferOrigin: Bool) -> [String] {
        let production = (resp.production_countries ?? []).compactMap(\.iso_3166_1)
        let origin = resp.origin_country ?? []
        let ordered = preferOrigin ? [origin, production] : [production, origin]
        let picked = ordered.first { !$0.isEmpty } ?? []
        var seen = Set<String>()
        return picked.map { $0.uppercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func imageURL(path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    public static func isReadAccessToken(_ s: String) -> Bool { TMDBService.isReadAccessToken(s) }
}

// MARK: - Wait-card facts (subset of /movie and /tv details)

nonisolated public struct TMDBMovieFacts: Codable, Sendable {
    public let tagline: String?
    public let originalTitle: String?
    public let budget: Int?
    public let revenue: Int?
    public let voteCount: Int?
}

nonisolated public struct TMDBTVFacts: Codable, Sendable {
    public let tagline: String?
    public let originalName: String?
    public let numberOfSeasons: Int?
    public let numberOfEpisodes: Int?
    public let status: String?
}
