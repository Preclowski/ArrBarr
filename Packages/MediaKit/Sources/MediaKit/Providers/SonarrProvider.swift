import Foundation

/// Sonarr as a field provider: whether a series is in the user's library, and
/// what the library calls it.
///
/// It can only be asked about a **TVDB** id. Sonarr's lookup keys on TheTVDB,
/// and a TMDB *series* id names a different show to it — passing one through
/// is how a link ends up opening something else. The graph resolves
/// tmdb-series → tvdb first (see `TMDBIdentityResolver`) or skips this
/// provider; `requiredIDs` is what makes that non-negotiable.
///
/// The score it carries is **TheTVDB's**, so that is what it is labelled as —
/// a score is only ever written under the name of the service that produced
/// it, never folded into somebody else's number.
public struct SonarrProvider: MediaProvider {
    public let id = ProviderID.sonarr
    public let supplies: MediaFieldSet = [.availability, .title, .ratings]
    public let cost = ProviderCost.local
    public let requiredIDs: Set<MediaID.Namespace> = [.tvdb]

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

    public var isConfigured: Bool { baseURL != nil && !(apiKey ?? "").isEmpty }

    /// Series only, and only once a TVDB id exists — `requiredIDs` covers the
    /// id, this covers the kind.
    public func canAnswer(_ identity: MediaIdentity) -> Bool {
        identity.kind == .series && identity.id(in: .tvdb) != nil
    }

    public func precedence(for field: MediaField) -> Int {
        switch field {
        case .availability: 100
        // The only source of a TheTVDB score; nobody else competes for it,
        // and ratings merge by service anyway.
        case .ratings: 80
        case .title: 10
        default: 0
        }
    }

    public func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment {
        let wanted = answerable(fields)
        guard !wanted.isEmpty, identity.kind == .series else {
            return MediaFragment(identity: identity)
        }
        guard let baseURL, let apiKey else { throw MediaError.notConfigured(id) }
        guard case .tvdb(let tvdbID)? = identity.id(in: .tvdb) else {
            // Not an error: the graph simply has nothing to ask with yet.
            return MediaFragment(identity: identity)
        }

        var components = URLComponents(
            url: baseURL.appending(path: "/api/v3/series/lookup"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: "tvdb:\(tvdbID)"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        let results = try await perform(URLRequest(url: components.url!),
                                        as: [Lookup].self,
                                        transport: transport,
                                        telemetry: telemetry,
                                        identity: identity,
                                        fields: wanted)

        // Trust the record's OWN tvdb id rather than the order results came
        // in: a term lookup is a search, and Sonarr is free to return
        // near-matches alongside the exact one.
        guard let series = results.first(where: { $0.tvdbId == tvdbID }) else {
            return MediaFragment(identity: identity)
        }

        var identity = identity
        if let imdb = series.imdbId, !imdb.isEmpty { identity.insert(.imdb(imdb)) }
        if let tmdb = series.tmdbId, tmdb > 0 { identity.insert(.tmdbSeries(tmdb)) }
        if let rowID = series.id, rowID > 0 { identity.insert(.arr(.sonarr, rowID)) }

        var fragment = MediaFragment(identity: identity)
        if wanted.contains(.title), let title = series.title {
            fragment.title = TitleFacts(title: title, year: series.year,
                                        overview: series.overview,
                                        seasonCount: series.statistics?.seasonCount,
                                        episodeCount: series.statistics?.totalEpisodeCount)
        }
        if wanted.contains(.ratings), let value = series.ratings?.value, value > 0 {
            fragment.ratings = Ratings(scores: [
                ServiceRating(service: .tvdb, value: value, voteCount: series.ratings?.votes),
            ])
        }
        if wanted.contains(.availability) {
            let inLibrary = (series.id ?? 0) > 0
            let hasEpisodes = (series.statistics?.episodeFileCount ?? 0) > 0
            fragment.availability = Availability(
                owned: inLibrary && hasEpisodes || inLibrary,
                sources: inLibrary ? ["Sonarr"] : [],
                absent: inLibrary ? [] : ["Sonarr"],
                downloaded: hasEpisodes ? ["Sonarr"] : [],
                links: link(slug: series.titleSlug, inLibrary: inLibrary)
                    .map { ["Sonarr": $0] } ?? [:])
        }
        return fragment
    }

    /// The show's own page when Sonarr has it, otherwise the add-a-series
    /// search already filled in.
    private func link(slug: String?, inLibrary: Bool) -> URL? {
        guard let baseURL else { return nil }
        if inLibrary, let slug, !slug.isEmpty {
            return baseURL.appending(path: "/series/\(slug)")
        }
        guard let slug, !slug.isEmpty else { return baseURL }
        var components = URLComponents(url: baseURL.appending(path: "/add/new"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "term", value: slug)]
        return components?.url ?? baseURL
    }

    private struct Lookup: Decodable {
        struct Statistics: Decodable {
            let seasonCount: Int?
            let episodeFileCount: Int?
            let totalEpisodeCount: Int?
        }
        struct Rating: Decodable {
            let value: Double?
            let votes: Int?
        }
        let id: Int?
        let titleSlug: String?
        let title: String?
        let year: Int?
        let overview: String?
        let ratings: Rating?
        let tvdbId: Int?
        let tmdbId: Int?
        let imdbId: String?
        let statistics: Statistics?
    }
}
