import Foundation

/// TMDB as a field provider.
///
/// One HTTP call answers every field it supplies: `append_to_response` folds
/// credits, watch providers and external ids into the detail response, which
/// is exactly the batching the planner wants — asking for `[.title, .credits]`
/// must not cost two round trips.
///
/// Catalog browsing (trending, discover, search) deliberately stays out. Those
/// are list queries, not per-title field queries, and forcing them through the
/// same door would bend both.
public struct TMDBProvider: MediaProvider {
    public let id = ProviderID.tmdb
    public let supplies: MediaFieldSet = [.title, .artwork, .ratings, .credits, .streaming]
    /// Free to call but rate-limited and off-network: anything the house can
    /// answer should be answered at home first.
    public let cost = ProviderCost.remote

    // Internal rather than private: the catalog half of this provider lives
    // in `TMDBCatalog.swift`, and an extension in another file cannot see a
    // private member.
    let auth: TMDBAuth
    private let region: String
    let language: String
    let transport: HTTPTransport
    let telemetry: MediaTelemetry?

    public init(apiKey: String, region: String = "US", language: String = "en-US",
                transport: HTTPTransport = URLSessionTransport(),
                telemetry: MediaTelemetry? = nil) {
        self.auth = TMDBAuth(credential: apiKey)
        self.region = region
        self.language = language
        self.transport = transport
        self.telemetry = telemetry
    }

    public var isConfigured: Bool { auth.isConfigured }

    /// TMDB owns what a title *is* — name, artwork, cast. It does not own what
    /// the user has: availability is not in `supplies` at all, and its score
    /// is one voice among the rating services, not the last word.
    public func precedence(for field: MediaField) -> Int {
        switch field {
        case .title, .artwork, .credits, .streaming: 100
        case .ratings: 50
        case .availability: 0
        }
    }

    public func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment {
        let wanted = answerable(fields)
        guard !wanted.isEmpty else { return MediaFragment(identity: identity) }
        guard let tmdbID = identity.tmdbID else { throw MediaError.notFound(id) }

        let path = identity.kind == .series ? "tv" : "movie"
        var appended = ["external_ids"]
        if wanted.contains(.credits) { appended.append("credits") }
        if wanted.contains(.streaming) { appended.append("watch/providers") }

        guard let request = auth.request(path: "/\(path)/\(tmdbID)", query: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: appended.joined(separator: ",")),
        ]) else { throw MediaError.notConfigured(id) }
        let payload = try await perform(request,
                                        as: Payload.self,
                                        transport: transport,
                                        telemetry: telemetry,
                                        identity: identity,
                                        fields: wanted)
        return fragment(from: payload, identity: identity, fields: wanted)
    }

    // MARK: - Wire

    private struct Payload: Decodable {
        struct Genre: Decodable { let name: String }
        struct Person: Decodable {
            let id: Int
            let name: String
            let character: String?
            let job: String?
            let profilePath: String?
            enum CodingKeys: String, CodingKey {
                case id, name, character, job
                case profilePath = "profile_path"
            }
        }
        struct Credits: Decodable {
            let cast: [Person]?
            let crew: [Person]?
        }
        struct ExternalIDs: Decodable {
            let imdbId: String?
            let tvdbId: Int?
            enum CodingKeys: String, CodingKey {
                case imdbId = "imdb_id"
                case tvdbId = "tvdb_id"
            }
        }
        struct WatchProviders: Decodable {
            struct Region: Decodable {
                struct Provider: Decodable {
                    let providerName: String?
                    enum CodingKeys: String, CodingKey { case providerName = "provider_name" }
                }
                let flatrate: [Provider]?
            }
            let results: [String: Region]?
        }

        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let overview: String?
        let releaseDate: String?
        let firstAirDate: String?
        let runtime: Int?
        let episodeRunTime: [Int]?
        let numberOfSeasons: Int?
        let numberOfEpisodes: Int?
        let genres: [Genre]?
        let posterPath: String?
        let backdropPath: String?
        let voteAverage: Double?
        let voteCount: Int?
        let credits: Credits?
        let externalIds: ExternalIDs?
        let watchProviders: WatchProviders?

        enum CodingKeys: String, CodingKey {
            case title, name, overview, runtime, genres, credits
            case originalTitle = "original_title"
            case originalName = "original_name"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case episodeRunTime = "episode_run_time"
            case numberOfSeasons = "number_of_seasons"
            case numberOfEpisodes = "number_of_episodes"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case voteAverage = "vote_average"
            case voteCount = "vote_count"
            case externalIds = "external_ids"
            case watchProviders = "watch/providers"
        }
    }

    private func fragment(from payload: Payload, identity: MediaIdentity,
                          fields: MediaFieldSet) -> MediaFragment {
        var identity = identity
        // Ids learned on the way: the next provider gets to key on IMDb
        // without a second lookup, which is most of what an id cross-walk is.
        if let imdb = payload.externalIds?.imdbId, !imdb.isEmpty {
            identity.insert(.imdb(imdb))
        }
        if let tvdb = payload.externalIds?.tvdbId, tvdb > 0 {
            identity.insert(.tvdb(tvdb))
        }
        var fragment = MediaFragment(identity: identity)

        if fields.contains(.title), let name = payload.title ?? payload.name {
            let date = payload.releaseDate ?? payload.firstAirDate
            fragment.title = TitleFacts(
                title: name,
                originalTitle: payload.originalTitle ?? payload.originalName,
                year: (date?.count ?? 0) >= 4 ? Int(date!.prefix(4)) : nil,
                overview: payload.overview?.isEmpty == true ? nil : payload.overview,
                runtimeMinutes: payload.runtime ?? payload.episodeRunTime?.first,
                genres: (payload.genres ?? []).map(\.name),
                seasonCount: payload.numberOfSeasons,
                episodeCount: payload.numberOfEpisodes)
        }
        if fields.contains(.artwork) {
            fragment.artwork = Artwork(poster: Self.imageURL(payload.posterPath, size: "w500"),
                                       backdrop: Self.imageURL(payload.backdropPath, size: "w1280"))
        }
        if fields.contains(.ratings), let score = payload.voteAverage, score > 0 {
            fragment.ratings = Ratings(scores: [
                ServiceRating(service: .tmdb, value: score, voteCount: payload.voteCount),
            ])
        }
        if fields.contains(.credits), let credits = payload.credits {
            let cast = (credits.cast ?? []).prefix(20).map {
                PersonCredit(id: $0.id, name: $0.name, role: $0.character,
                             profilePath: $0.profilePath, isCast: true)
            }
            let crew = (credits.crew ?? []).filter { $0.job == "Director" }.map {
                PersonCredit(id: $0.id, name: $0.name, role: $0.job,
                             profilePath: $0.profilePath, isCast: false)
            }
            fragment.credits = Credits(people: Array(cast) + crew)
        }
        if fields.contains(.streaming) {
            let flatrate = payload.watchProviders?.results?[region]?.flatrate ?? []
            fragment.streaming = StreamingAvailability(
                region: region, flatrate: flatrate.compactMap(\.providerName))
        }
        return fragment
    }

    public static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
