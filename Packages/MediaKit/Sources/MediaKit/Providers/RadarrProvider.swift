import Foundation

/// Radarr as a field provider: the multi-service ratings its metadata proxy
/// carries (IMDb, Rotten Tomatoes, Metacritic — none of which TMDB has), plus
/// whether the film is in the user's library at all.
///
/// It is a box on the LAN, so it is cheaper than TMDB and answers first for
/// anything both know. Movies only — Radarr's lookup is movie-shaped, and a
/// series query is simply not answerable here.
public struct RadarrProvider: MediaProvider {
    public let id = ProviderID.radarr
    public let supplies: MediaFieldSet = [.ratings, .availability, .title]
    public let cost = ProviderCost.local

    private let baseURL: URL?
    private let apiKey: String?
    private let transport: HTTPTransport
    private let telemetry: MediaTelemetry?

    public init(credentials: ProviderCredentials?,
                transport: HTTPTransport = URLSessionTransport(),
                telemetry: MediaTelemetry? = nil) {
        self.baseURL = credentials?.baseURL
        self.apiKey = credentials?.apiKey
        self.transport = transport
        self.telemetry = telemetry
    }

    public var isConfigured: Bool {
        baseURL != nil && !(apiKey ?? "").isEmpty
    }

    /// Films only. Sonarr's half of the library is not Radarr's to guess at,
    /// and being planned for a series only produced empty answers that read
    /// as failures in the debug report.
    public func canAnswer(_ identity: MediaIdentity) -> Bool {
        identity.kind == .movie && identity.tmdbID != nil
    }

    /// Radarr owns "do I have this" outright; its ratings beat TMDB's single
    /// score because they carry services TMDB cannot; its title is a fallback
    /// only — it is whatever the user's library happens to call the file.
    public func precedence(for field: MediaField) -> Int {
        switch field {
        case .availability: 100
        case .ratings: 80
        case .title: 10
        default: 0
        }
    }

    public func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment {
        let wanted = answerable(fields)
        guard !wanted.isEmpty, identity.kind == .movie else {
            return MediaFragment(identity: identity)
        }
        guard let baseURL, let apiKey, let tmdbID = identity.tmdbID else {
            throw MediaError.notConfigured(id)
        }

        var components = URLComponents(
            url: baseURL.appending(path: "/api/v3/movie/lookup/tmdb"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "tmdbId", value: String(tmdbID)),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        let payload = try await perform(URLRequest(url: components.url!),
                                        as: Lookup.self,
                                        transport: transport,
                                        telemetry: telemetry,
                                        identity: identity,
                                        fields: wanted)

        var identity = identity
        if let imdb = payload.imdbId, !imdb.isEmpty { identity.insert(.imdb(imdb)) }
        // A lookup hit that is already in the library carries its Radarr row
        // id; an unknown film comes back with id 0.
        if let rowID = payload.id, rowID > 0 { identity.insert(.arr(.radarr, rowID)) }

        var fragment = MediaFragment(identity: identity)
        if wanted.contains(.title), let title = payload.title {
            fragment.title = TitleFacts(title: title, year: payload.year,
                                        overview: payload.overview,
                                        runtimeMinutes: payload.runtime)
        }
        if wanted.contains(.ratings), let ratings = payload.ratings {
            var scores: [ServiceRating] = []
            if let value = ratings.imdb?.value, value > 0 {
                scores.append(ServiceRating(service: .imdb, value: value,
                                            voteCount: ratings.imdb?.votes))
            }
            if let value = ratings.rottenTomatoes?.value, value > 0 {
                scores.append(ServiceRating(service: .rottenTomatoes, value: value))
            }
            if let value = ratings.metacritic?.value, value > 0 {
                scores.append(ServiceRating(service: .metacritic, value: value))
            }
            if let value = ratings.tmdb?.value, value > 0 {
                scores.append(ServiceRating(service: .tmdb, value: value,
                                            voteCount: ratings.tmdb?.votes))
            }
            if !scores.isEmpty { fragment.ratings = Ratings(scores: scores) }
        }
        if wanted.contains(.availability) {
            // Present in the library is "owned"; a file on disk is a stronger
            // yes but not a different field. Watched state is a media
            // server's business — Radarr has no idea, and must not claim it.
            let inLibrary = (payload.id ?? 0) > 0
            fragment.availability = Availability(
                owned: inLibrary || payload.hasFile == true,
                sources: inLibrary ? ["Radarr"] : [],
                absent: inLibrary ? [] : ["Radarr"],
                downloaded: payload.hasFile == true ? ["Radarr"] : [],
                links: link(slug: payload.titleSlug, inLibrary: inLibrary)
                    .map { ["Radarr": $0] } ?? [:])
        }
        return fragment
    }

    /// The film's own page when Radarr has it, otherwise the add-a-film
    /// search already filled in — the two things "Radarr" can usefully mean
    /// from a detail page.
    private func link(slug: String?, inLibrary: Bool) -> URL? {
        guard let baseURL else { return nil }
        if inLibrary, let slug, !slug.isEmpty {
            return baseURL.appending(path: "/movie/\(slug)")
        }
        guard let slug, !slug.isEmpty else { return baseURL }
        var components = URLComponents(url: baseURL.appending(path: "/add/new"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "term", value: slug)]
        return components?.url ?? baseURL
    }

    private struct Lookup: Decodable {
        struct Value: Decodable {
            let value: Double?
            let votes: Int?
        }
        struct RatingsBlock: Decodable {
            let imdb: Value?
            let tmdb: Value?
            let rottenTomatoes: Value?
            let metacritic: Value?
        }
        let id: Int?
        let titleSlug: String?
        let title: String?
        let year: Int?
        let overview: String?
        let runtime: Int?
        let imdbId: String?
        let hasFile: Bool?
        let ratings: RatingsBlock?
    }
}
