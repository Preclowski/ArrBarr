import Foundation

// MARK: - Wire types
//
// TMDB v3 API. Only fields we actually consume are decoded — the wire payload
// is much richer (production_companies, runtime, original_language, …) but
// pulling everything makes the codable surface fragile when TMDB tweaks schema.

public struct TMDBPerson: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let knownForDepartment: String?
    public let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case knownForDepartment = "known_for_department"
        case profilePath = "profile_path"
    }
}

public struct TMDBPagedPeople: Decodable, Sendable {
    public let results: [TMDBPerson]
}

public struct TMDBMovieSummary: Decodable, Sendable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case id, title, overview, character, popularity
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

public struct TMDBTVSummary: Decodable, Sendable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case id, name, overview, character, popularity
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

public struct TMDBMovieCreditsResponse: Decodable, Sendable {
    public let cast: [TMDBMovieSummary]
}

public struct TMDBTVCreditsResponse: Decodable, Sendable {
    public let cast: [TMDBTVSummary]
}

public struct TMDBDiscoverMovieResponse: Decodable, Sendable {
    public let results: [TMDBMovieSummary]
}

public struct TMDBDiscoverTVResponse: Decodable, Sendable {
    public let results: [TMDBTVSummary]
}

// MARK: - Genre maps
//
// TMDB exposes /genre/movie/list and /genre/tv/list but those values are
// stable across decades — embedding them avoids an extra round-trip per
// session and lets the LLM pick a genre by name without a setup tool call.

public enum TMDBGenres {
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
// Plain struct over URLSession — TMDB endpoints are stateless and don't
// need per-instance caching. Sendable so it can be passed across actors.

public struct TMDBClient: Sendable {
    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    /// Cheap auth check — `/configuration` returns 200 even on a v3 key
    /// without scopes. 401 means the key is wrong.
    public func testConnection() async throws {
        let _: TMDBConfigResponse = try await get(path: "/configuration", query: [])
    }

    public func searchPerson(query: String) async throws -> [TMDBPerson] {
        let resp: TMDBPagedPeople = try await get(
            path: "/search/person",
            query: [URLQueryItem(name: "query", value: query)]
        )
        return resp.results
    }

    public func personMovieCredits(personId: Int) async throws -> [TMDBMovieSummary] {
        let resp: TMDBMovieCreditsResponse = try await get(
            path: "/person/\(personId)/movie_credits", query: []
        )
        return resp.cast
    }

    public func personTVCredits(personId: Int) async throws -> [TMDBTVSummary] {
        let resp: TMDBTVCreditsResponse = try await get(
            path: "/person/\(personId)/tv_credits", query: []
        )
        return resp.cast
    }

    /// TMDB discover. `startYear`/`endYear` (inclusive) expand to ISO
    /// `primary_release_date.gte/lte` bounds — covers "filmy z lat 90".
    public func discoverMovies(
        genreIds: [Int] = [],
        startYear: Int? = nil,
        endYear: Int? = nil,
        sortBy: String = "popularity.desc",
        minVoteCount: Int = 50,
        voteAverageGte: Double? = nil,
        runtimeLte: Int? = nil,
        runtimeGte: Int? = nil
    ) async throws -> [TMDBMovieSummary] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "vote_count.gte", value: String(minVoteCount)),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        if !genreIds.isEmpty {
            query.append(URLQueryItem(name: "with_genres", value: genreIds.map(String.init).joined(separator: ",")))
        }
        if let y = startYear {
            query.append(URLQueryItem(name: "primary_release_date.gte", value: "\(y)-01-01"))
        }
        if let y = endYear {
            query.append(URLQueryItem(name: "primary_release_date.lte", value: "\(y)-12-31"))
        }
        if let v = voteAverageGte {
            query.append(URLQueryItem(name: "vote_average.gte", value: String(v)))
        }
        if let r = runtimeLte {
            query.append(URLQueryItem(name: "with_runtime.lte", value: String(r)))
        }
        if let r = runtimeGte {
            query.append(URLQueryItem(name: "with_runtime.gte", value: String(r)))
        }
        let resp: TMDBDiscoverMovieResponse = try await get(path: "/discover/movie", query: query)
        return resp.results
    }

    public func discoverTV(
        genreIds: [Int] = [],
        startYear: Int? = nil,
        endYear: Int? = nil,
        sortBy: String = "popularity.desc",
        minVoteCount: Int = 20,
        voteAverageGte: Double? = nil
    ) async throws -> [TMDBTVSummary] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "vote_count.gte", value: String(minVoteCount)),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        if !genreIds.isEmpty {
            query.append(URLQueryItem(name: "with_genres", value: genreIds.map(String.init).joined(separator: ",")))
        }
        if let y = startYear {
            query.append(URLQueryItem(name: "first_air_date.gte", value: "\(y)-01-01"))
        }
        if let y = endYear {
            query.append(URLQueryItem(name: "first_air_date.lte", value: "\(y)-12-31"))
        }
        if let v = voteAverageGte {
            query.append(URLQueryItem(name: "vote_average.gte", value: String(v)))
        }
        let resp: TMDBDiscoverTVResponse = try await get(path: "/discover/tv", query: query)
        return resp.results
    }

    // MARK: - Image URLs

    /// `path` is the `poster_path` / `profile_path` we get from TMDB —
    /// already starts with `/`. `size` is a TMDB image preset (w92, w154,
    /// w185, w342, w500, w780, original).
    public static func imageURL(path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    // MARK: - Plumbing

    private struct TMDBConfigResponse: Decodable { let images: TMDBImages? }
    private struct TMDBImages: Decodable { let secure_base_url: String? }

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        guard isConfigured else { throw HTTPError.missingApiKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        var allQuery = query
        allQuery.append(URLQueryItem(name: "api_key", value: apiKey))
        components.queryItems = allQuery
        guard let url = components.url else { throw HTTPError.badURL }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(from: url)
        } catch {
            throw HTTPError.transport(error)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw HTTPError.status(http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }
}
