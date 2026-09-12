import Foundation
import ArrCore

/// TonightBarr's own TMDB access. ArrCore's `TMDBClient` stays untouched (the
/// copy is a dependency we want to keep pristine), so the endpoints this app
/// needs beyond it — trending, curated lists, paged discover, multi-search,
/// full details via `append_to_response` — live here. Accepts the same v3 key
/// or v4 read-access token as ArrCore.
public struct TMDBService: Sendable {
    public let apiKey: String
    public let region: String
    public let session: URLSession

    public init(apiKey: String, region: String = "PL", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.region = region
        self.session = session
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Raw list decoding

    /// One decodable shape for every TMDB list payload: movie rows carry
    /// `title`/`release_date`, TV rows `name`/`first_air_date`, trending and
    /// multi-search add `media_type`.
    struct RawSummary: Decodable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let voteAverage: Double?
        let voteCount: Int?
        let overview: String?
        let genreIds: [Int]?
        let popularity: Double?
        let profilePath: String?
        /// Only present in credit lists (combined_credits): what the person
        /// did on this title.
        let character: String?
        let job: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview, popularity, character, job
            case profilePath = "profile_path"
            case mediaType = "media_type"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
            case genreIds = "genre_ids"
        }

        func item(defaultType: MediaType) -> MediaItem? {
            let type: MediaType
            switch mediaType {
            case "movie": type = .movie
            case "tv": type = .tv
            case "person": return nil
            default: type = defaultType
            }
            let date = type == .movie ? releaseDate : firstAirDate
            let year = (date?.count ?? 0) >= 4 ? Int(date!.prefix(4)) : nil
            guard let title = (type == .movie ? title : name) ?? title ?? name else { return nil }
            return MediaItem(tmdbId: id, type: type, title: title, year: year,
                             posterPath: posterPath, backdropPath: backdropPath,
                             rating: voteAverage, voteCount: voteCount,
                             overview: overview, genreIds: genreIds ?? [])
        }
    }

    struct Page: Decodable {
        let results: [RawSummary]
        let totalPages: Int?
        enum CodingKeys: String, CodingKey {
            case results
            case totalPages = "total_pages"
        }
    }

    // MARK: - Lists

    public enum TrendingWindow: String, Sendable { case day, week }

    public func trending(_ type: MediaType, window: TrendingWindow = .week, page: Int = 1) async throws -> [MediaItem] {
        try await list(path: "/trending/\(type.rawValue)/\(window.rawValue)", type: type, page: page)
    }

    public enum Curated: String, Sendable {
        case popular
        case topRated = "top_rated"
        case nowPlaying = "now_playing"   // movies only
        case upcoming                     // movies only
        case onTheAir = "on_the_air"      // TV only
    }

    public func curated(_ category: Curated, _ type: MediaType, page: Int = 1) async throws -> [MediaItem] {
        var query = [URLQueryItem(name: "page", value: String(page))]
        // Theatrical windows are regional — everything else is global.
        if type == .movie, category == .nowPlaying || category == .upcoming {
            query.append(URLQueryItem(name: "region", value: region))
        }
        let result: Page = try await get(path: "/\(type.rawValue)/\(category.rawValue)", query: query)
        return result.results.compactMap { $0.item(defaultType: type) }
    }

    /// A theatrical listing row: the item plus its exact regional release
    /// date, so the In Theaters page can group the repertoire by month.
    public struct TheatricalItem: Identifiable, Sendable {
        public let item: MediaItem
        public let releaseDate: Date?
        public var id: String { item.id }
    }

    private static let releaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `now_playing` / `upcoming` with the release date preserved.
    public func theatrical(_ category: Curated, page: Int = 1) async throws -> [TheatricalItem] {
        let result: Page = try await get(path: "/movie/\(category.rawValue)", query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "region", value: region),
        ])
        return result.results.compactMap { raw in
            raw.item(defaultType: .movie).map { item in
                TheatricalItem(item: item,
                               releaseDate: raw.releaseDate.flatMap {
                                   Self.releaseDateFormatter.date(from: $0)
                               })
            }
        }
    }

    /// Resolve a known film (award winners) to its TMDB entry. TMDB's
    /// primary release year sometimes predates the award year by one
    /// (festival premieres), so the year is tried, then relaxed.
    public func movieMatch(title: String, year: Int?) async throws -> MediaItem? {
        func search(year: Int?) async throws -> [MediaItem] {
            var query = [
                URLQueryItem(name: "query", value: title),
                URLQueryItem(name: "include_adult", value: "false"),
            ]
            if let year {
                query.append(URLQueryItem(name: "primary_release_year", value: String(year)))
            }
            let page: Page = try await get(path: "/search/movie", query: query)
            return page.results.compactMap { $0.item(defaultType: .movie) }
        }
        if let year {
            if let hit = try await search(year: year).first { return hit }
            if let hit = try await search(year: year - 1).first { return hit }
        }
        let loose = try await search(year: nil)
        if let year, let close = loose.first(where: { abs(($0.year ?? 0) - year) <= 2 }) {
            return close
        }
        return loose.first
    }

    public func search(_ query: String, page: Int = 1) async throws -> [MediaItem] {
        let page: Page = try await get(path: "/search/multi", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: String(page)),
        ])
        return page.results.compactMap { $0.item(defaultType: .movie) }
    }

    /// Categorized search. One dedicated call per category — multi-search
    /// crams all three into a single 20-row page, which starved the People
    /// section to a couple of hits.
    public func searchAll(_ query: String) async throws -> SearchResults {
        async let movies = searchPage(.movies, query: query, page: 1)
        async let shows = searchPage(.series, query: query, page: 1)
        async let people = searchPage(.people, query: query, page: 1)
        let (m, s, p) = try await (movies, shows, people)
        var results = SearchResults()
        results.movies = m.items
        results.shows = s.items
        results.people = p.people
        return results
    }

    public enum SearchCategory: String, Hashable, Sendable {
        case movies, series, people

        var path: String {
            switch self {
            case .movies: return "/search/movie"
            case .series: return "/search/tv"
            case .people: return "/search/person"
            }
        }
    }

    public struct SearchPage: Sendable {
        public var items: [MediaItem] = []
        public var people: [PersonHit] = []
        public var totalPages: Int = 1
    }

    /// One page of one category — the full category view pages through this.
    public func searchPage(_ category: SearchCategory, query: String, page: Int) async throws -> SearchPage {
        let raw: Page = try await get(path: category.path, query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: String(page)),
        ])
        var result = SearchPage(totalPages: raw.totalPages ?? 1)
        switch category {
        case .movies:
            result.items = raw.results.compactMap { $0.item(defaultType: .movie) }
        case .series:
            result.items = raw.results.compactMap { $0.item(defaultType: .tv) }
        case .people:
            result.people = raw.results.compactMap { r in
                r.name.map { PersonHit(id: r.id, name: $0, profilePath: r.profilePath) }
            }
        }
        return result
    }

    public func discover(_ filter: DiscoverFilter, page: Int = 1) async throws -> [MediaItem] {
        var query = filter.queryItems(region: region)
        query.append(URLQueryItem(name: "page", value: String(page)))
        let result: Page = try await get(path: "/discover/\(filter.type.rawValue)", query: query)
        return result.results.compactMap { $0.item(defaultType: filter.type) }
    }

    private func list(path: String, type: MediaType, page: Int) async throws -> [MediaItem] {
        let result: Page = try await get(path: path, query: [
            URLQueryItem(name: "page", value: String(page)),
        ])
        return result.results.compactMap { $0.item(defaultType: type) }
    }

    // MARK: - People

    /// Full person profile + filmography in one round trip.
    public func person(personId: Int) async throws -> PersonDetails {
        struct RawPerson: Decodable {
            struct Credits: Decodable {
                let cast: [RawSummary]?
                let crew: [RawSummary]?
            }
            let id: Int
            let name: String
            let biography: String?
            let birthday: String?
            let deathday: String?
            let placeOfBirth: String?
            let profilePath: String?
            let knownForDepartment: String?
            let combinedCredits: Credits?
            enum CodingKeys: String, CodingKey {
                case id, name, biography, birthday, deathday
                case placeOfBirth = "place_of_birth"
                case profilePath = "profile_path"
                case knownForDepartment = "known_for_department"
                case combinedCredits = "combined_credits"
            }
        }
        let raw: RawPerson = try await get(
            path: "/person/\(personId)",
            query: [URLQueryItem(name: "append_to_response", value: "combined_credits")])
        var seen = Set<String>()
        var roles: [String: String] = [:]
        let credits = ((raw.combinedCredits?.cast ?? []) + (raw.combinedCredits?.crew ?? []))
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .compactMap { raw -> MediaItem? in
                guard let item = raw.item(defaultType: .movie) else { return nil }
                // What they did on it — the character they played, or the
                // crew job. First credit wins: the list is already ranked,
                // and a title someone both wrote and directed shouldn't
                // appear twice.
                if let role = [raw.character, raw.job]
                    .compactMap({ $0?.trimmingCharacters(in: .whitespaces) })
                    .first(where: { !$0.isEmpty }) {
                    roles[item.id] = roles[item.id] ?? role
                }
                return item
            }
            .filter { $0.posterPath != nil && seen.insert($0.id).inserted }
        return PersonDetails(
            id: raw.id,
            name: raw.name,
            biography: raw.biography?.isEmpty == true ? nil : raw.biography,
            birthday: raw.birthday,
            deathday: raw.deathday,
            placeOfBirth: raw.placeOfBirth,
            profilePath: raw.profilePath,
            knownForDepartment: raw.knownForDepartment,
            movies: credits.filter { $0.type == .movie },
            shows: credits.filter { $0.type == .tv },
            roles: roles,
            backdropPath: credits.first { $0.backdropPath != nil }?.backdropPath
        )
    }

    // MARK: - TMDB lists

    /// Hand-picked, verified public TMDB lists shown in the Lists hub.
    /// TMDB has no list-search endpoint, so discovery is: these anchors plus
    /// `popularLists()` aggregation. Names/counts are fetched live.
    public static let featuredListIds: [Int] = [
        634,   // Top 250 IMDB
        28,    // Best Picture Winners — The Academy Awards
        10,    // Top 50 Grossing Films of All Time
        1,     // The Marvel Universe
        3682,  // AFI's 100 Years… 100 Laughs
    ]

    struct ListMeta: Decodable {
        let id: Int
        let name: String
        let itemCount: Int?
        enum CodingKeys: String, CodingKey {
            case id, name
            case itemCount = "item_count"
        }
    }

    /// A list's name, size and contents — TMDB answers all three with one
    /// `/list/{id}` payload, so anything that wants both (the Discover row
    /// needs the name to label a tile and a poster to put behind it) must ask
    /// for them together rather than twice.
    public func list(id: Int, page: Int = 1) async throws -> (ref: TMDBListRef, items: [MediaItem]) {
        struct ListPayload: Decodable {
            let id: Int
            let name: String
            let itemCount: Int?
            let items: [RawSummary]
            enum CodingKeys: String, CodingKey {
                case id, name, items
                case itemCount = "item_count"
            }
        }
        let payload: ListPayload = try await get(path: "/list/\(id)", query: [
            URLQueryItem(name: "page", value: String(page)),
        ])
        return (TMDBListRef(id: payload.id, name: payload.name,
                            itemCount: payload.itemCount ?? 0),
                payload.items.compactMap { $0.item(defaultType: .movie) })
    }

    public func listRef(id: Int) async throws -> TMDBListRef {
        try await list(id: id).ref
    }

    /// Discover lists the TMDB community keeps: pull the lists that today's
    /// trending movies appear in, rank by how often they show up and their
    /// size. That's as close to "browse lists" as the API allows.
    public func popularLists(excluding excluded: Set<Int> = []) async throws -> [TMDBListRef] {
        struct ListsPage: Decodable { let results: [ListMeta]? }
        let seeds = try await trending(.movie).prefix(8)
        var hits: [Int: (meta: ListMeta, count: Int)] = [:]
        try await withThrowingTaskGroup(of: [ListMeta].self) { group in
            for seed in seeds {
                group.addTask {
                    let page: ListsPage = try await self.get(
                        path: "/movie/\(seed.tmdbId)/lists", query: [])
                    return page.results ?? []
                }
            }
            for try await metas in group {
                for meta in metas where (meta.itemCount ?? 0) >= 10 {
                    hits[meta.id, default: (meta, 0)].count += 1
                }
            }
        }
        return hits.values
            .filter { !excluded.contains($0.meta.id) }
            .sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : ($0.meta.itemCount ?? 0) > ($1.meta.itemCount ?? 0)
            }
            .prefix(18)
            .map { TMDBListRef(id: $0.meta.id, name: $0.meta.name, itemCount: $0.meta.itemCount ?? 0) }
    }

    /// Items of a public TMDB list. The v3 endpoint pages like discover does.
    public func listItems(listId: Int, page: Int = 1) async throws -> [MediaItem] {
        try await list(id: listId, page: page).items
    }

    // MARK: - Details

    public func details(for item: MediaItem) async throws -> TitleDetails {
        // `lists` is a movie-only append — TMDB has no TV equivalent.
        let appended = item.type == .movie
            ? "videos,credits,recommendations,reviews,watch/providers,lists,images"
            : "videos,credits,recommendations,reviews,watch/providers,images"
        let raw: RawDetails = try await get(
            path: "/\(item.type.rawValue)/\(item.tmdbId)",
            query: [URLQueryItem(name: "append_to_response", value: appended),
                    // Title logos are language-stamped; ask for English and
                    // the language-neutral ones, or the appended images come
                    // back in whatever the account default is.
                    URLQueryItem(name: "include_image_language", value: "en,null")]
        )
        return TitleDetails(raw: raw, base: item, region: region)
    }

    // MARK: - Plumbing (mirrors ArrCore's TMDBClient auth behavior)

    func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        guard isConfigured else { throw HTTPError.missingApiKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        let useBearer = TMDBClient.isReadAccessToken(apiKey)
        var allQuery = query
        allQuery.append(URLQueryItem(name: "language", value: "en-US"))
        if !useBearer {
            allQuery.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components.queryItems = allQuery
        guard let url = components.url else { throw HTTPError.badURL }
        var request = URLRequest(url: url)
        if useBearer {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: request)
        } catch {
            throw HTTPError.transport(error)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, body: String(data: data, encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }
}

/// A person page: profile facts plus filmography split by media type.
public struct PersonDetails: Sendable {
    public let id: Int
    public let name: String
    public let biography: String?
    public let birthday: String?
    public let deathday: String?
    public let placeOfBirth: String?
    public let profilePath: String?
    public let knownForDepartment: String?
    public let movies: [MediaItem]
    public let shows: [MediaItem]
    /// `MediaItem.id` → the person's role on that title ("Ellen Ripley",
    /// "Director"). Rendered under the poster in their filmography.
    public let roles: [String: String]
    public let backdropPath: String?

    public var photoURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w500") }
    public var backdropURL: URL? { TMDBClient.imageURL(path: backdropPath, size: "w1280") }
}

/// A person row in search results.
public struct PersonHit: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let profilePath: String?

    public var photoURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }
}

/// Categorized multi-search payload.
public struct SearchResults: Sendable {
    public var movies: [MediaItem] = []
    public var shows: [MediaItem] = []
    public var people: [PersonHit] = []

    public var isEmpty: Bool { movies.isEmpty && shows.isEmpty && people.isEmpty }
}
