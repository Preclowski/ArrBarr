import Testing
import Foundation
@testable import MediaKit

/// A transport that answers from a script instead of a server, and counts how
/// many times it was asked — which is what most of these tests assert on.
private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    var delay: Duration = .zero

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    convenience init(json: String, status: Int = 200) {
        self.init([HTTPResponse(status: status, data: Data(json.utf8))])
    }

    var callCount: Int { lock.withLock { requests.count } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else {
                throw MediaError.unreachable("fake")
            }
            return responses.count == 1 ? responses[0] : responses.removeFirst()
        }
    }
}

/// A provider with no network at all: it answers whatever it was built with,
/// and records how often it was called.
private final class StubProvider: MediaProvider, @unchecked Sendable {
    let id: ProviderID
    let supplies: MediaFieldSet
    let cost: ProviderCost
    let isConfigured: Bool
    let answersFromIndex: Bool
    private let precedences: [MediaField: Int]
    private let build: @Sendable (MediaIdentity) throws -> MediaFragment
    private let lock = NSLock()
    private var calls = 0

    init(id: ProviderID, supplies: MediaFieldSet, cost: ProviderCost = .remote,
         isConfigured: Bool = true, answersFromIndex: Bool = true,
         precedences: [MediaField: Int] = [:],
         build: @escaping @Sendable (MediaIdentity) throws -> MediaFragment) {
        self.id = id
        self.supplies = supplies
        self.cost = cost
        self.isConfigured = isConfigured
        self.answersFromIndex = answersFromIndex
        self.precedences = precedences
        self.build = build
    }

    var callCount: Int { lock.withLock { calls } }

    func precedence(for field: MediaField) -> Int { precedences[field] ?? 0 }

    func fetch(_ identity: MediaIdentity, fields: MediaFieldSet) async throws -> MediaFragment {
        lock.withLock { calls += 1 }
        return try build(identity)
    }
}

@Suite("TMDB provider")
struct TMDBProviderTests {
    private static let movieJSON = """
    {
      "id": 603, "title": "The Matrix", "original_title": "The Matrix",
      "overview": "A hacker learns the truth.", "release_date": "1999-03-30",
      "runtime": 136, "genres": [{"name": "Action"}, {"name": "Science Fiction"}],
      "poster_path": "/poster.jpg", "backdrop_path": "/backdrop.jpg",
      "vote_average": 8.2, "vote_count": 25000,
      "external_ids": {"imdb_id": "tt0133093"},
      "credits": {
        "cast": [{"id": 6384, "name": "Keanu Reeves", "character": "Neo"}],
        "crew": [{"id": 9339, "name": "Lana Wachowski", "job": "Director"},
                 {"id": 1, "name": "Someone", "job": "Gaffer"}]
      },
      "watch/providers": {"results": {"PL": {"flatrate": [{"provider_name": "Max"}]}}}
    }
    """

    @Test("one call answers every requested field")
    func singleRoundTrip() async throws {
        let transport = FakeTransport(json: Self.movieJSON)
        let provider = TMDBProvider(apiKey: "k", region: "PL", transport: transport)
        let fragment = try await provider.fetch(.tmdbMovie(603),
                                                fields: [.title, .artwork, .ratings, .credits, .streaming])

        #expect(transport.callCount == 1)
        #expect(fragment.title?.title == "The Matrix")
        #expect(fragment.title?.year == 1999)
        #expect(fragment.title?.runtimeMinutes == 136)
        #expect(fragment.artwork?.poster?.absoluteString.hasSuffix("/poster.jpg") == true)
        #expect(fragment.ratings?.value(for: .tmdb) == 8.2)
        #expect(fragment.credits?.cast.first?.role == "Neo")
        #expect(fragment.credits?.crew.map(\.name) == ["Lana Wachowski"])
        #expect(fragment.streaming?.flatrate == ["Max"])
    }

    @Test("append_to_response only carries what was asked for")
    func appendsOnlyRequested() async throws {
        let transport = FakeTransport(json: Self.movieJSON)
        let provider = TMDBProvider(apiKey: "k", transport: transport)
        _ = try await provider.fetch(.tmdbMovie(603), fields: .title)

        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url.contains("append_to_response=external_ids"))
        #expect(!url.contains("credits"))
    }

    @Test("ids learned on the way join the identity")
    func learnsIDs() async throws {
        let transport = FakeTransport(json: Self.movieJSON)
        let provider = TMDBProvider(apiKey: "k", transport: transport)
        let fragment = try await provider.fetch(.tmdbMovie(603), fields: .title)
        #expect(fragment.identity.imdbID == "tt0133093")
    }

    @Test("HTTP failures map to errors the planner understands")
    func errorMapping() async {
        let cases: [(Int, MediaError)] = [
            (401, .unauthorized(.tmdb)), (404, .notFound(.tmdb)),
            (429, .rateLimited(.tmdb, retryAfter: nil)), (500, .unreachable(.tmdb)),
        ]
        for (status, expected) in cases {
            let transport = FakeTransport([HTTPResponse(status: status, data: Data("{}".utf8))])
            let provider = TMDBProvider(apiKey: "k", transport: transport)
            await #expect(throws: expected) {
                try await provider.fetch(.tmdbMovie(603), fields: .title)
            }
        }
    }

    @Test("no key means not configured, and nothing is asked for")
    func unconfigured() {
        let provider = TMDBProvider(apiKey: "", transport: FakeTransport([]))
        #expect(!provider.isConfigured)
        #expect(provider.answerable(.all).isEmpty)
    }
}

@Suite("Radarr provider")
struct RadarrProviderTests {
    private static let lookupJSON = """
    {
      "id": 12, "title": "The Matrix", "year": 1999, "hasFile": true,
      "imdbId": "tt0133093",
      "ratings": {
        "imdb": {"value": 8.7, "votes": 1900000},
        "rottenTomatoes": {"value": 83},
        "metacritic": {"value": 73},
        "tmdb": {"value": 8.2}
      }
    }
    """

    @Test("the services TMDB doesn't have come through")
    func ratings() async throws {
        let transport = FakeTransport(json: Self.lookupJSON)
        let provider = RadarrProvider(
            credentials: .init(baseURL: URL(string: "http://nas.local:7878"), apiKey: "abc"),
            transport: transport)
        let fragment = try await provider.fetch(.tmdbMovie(603), fields: [.ratings, .availability])

        #expect(fragment.ratings?.value(for: .imdb) == 8.7)
        #expect(fragment.ratings?.value(for: .rottenTomatoes) == 83)
        #expect(fragment.ratings?.value(for: .metacritic) == 73)
        #expect(fragment.availability?.owned == true)
        #expect(fragment.availability?.sources == ["Radarr"])
        // Radarr has no idea what you watched — it must not claim it.
        #expect(fragment.availability?.watched == false)
        #expect(fragment.identity.contains(.arr(.radarr, 12)))
    }

    @Test("a series is not answerable here, and that is not an error")
    func seriesIsSkipped() async throws {
        let transport = FakeTransport(json: Self.lookupJSON)
        let provider = RadarrProvider(
            credentials: .init(baseURL: URL(string: "http://nas.local:7878"), apiKey: "abc"),
            transport: transport)
        let fragment = try await provider.fetch(.tmdbSeries(1396), fields: .ratings)
        #expect(fragment.populated.isEmpty)
        #expect(transport.callCount == 0)
    }
}

@Suite("Graph planning")
struct GraphTests {
    private func metadata(_ title: String = "TMDB title", score: Double = 8.2) -> StubProvider {
        StubProvider(id: .tmdb, supplies: [.title, .artwork, .ratings], cost: .remote,
                     precedences: [.title: 100, .artwork: 100, .ratings: 50]) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.title = TitleFacts(title: title, year: 1999)
            fragment.artwork = Artwork(poster: URL(string: "https://tmdb.invalid/p.jpg"))
            fragment.ratings = Ratings(scores: [.init(service: .tmdb, value: score)])
            return fragment
        }
    }

    private func library(owned: Bool = true) -> StubProvider {
        StubProvider(id: .radarr, supplies: [.title, .ratings, .availability], cost: .local,
                     precedences: [.availability: 100, .ratings: 80, .title: 10]) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.title = TitleFacts(title: "Matrix, The (1999) [1080p]")
            fragment.ratings = Ratings(scores: [.init(service: .imdb, value: 8.7)])
            fragment.availability = Availability(owned: owned, sources: ["Radarr"])
            return fragment
        }
    }

    @Test("each field goes to the source that owns it")
    func precedencePerField() async {
        let graph = MediaGraph(providers: [metadata(), library()])
        let snapshot = await graph.fetch(.tmdbMovie(603), fields: .card)

        #expect(snapshot.title?.title == "TMDB title")
        #expect(snapshot.provenance[.title]?.provider == .tmdb)
        #expect(snapshot.availability?.owned == true)
        #expect(snapshot.provenance[.availability]?.provider == .radarr)
        // Ratings are the merging case: both sources contribute.
        #expect(snapshot.ratings?.value(for: .tmdb) == 8.2)
        #expect(snapshot.ratings?.value(for: .imdb) == 8.7)
        #expect(snapshot.provenance[.ratings]?.provider == .radarr)
    }

    @Test("a provider that can't answer a field is never asked")
    func onlyAskWhoCanAnswer() async {
        let tmdb = metadata()
        let radarr = library()
        let graph = MediaGraph(providers: [tmdb, radarr])
        _ = await graph.fetch(.tmdbMovie(603), fields: .availability)

        #expect(radarr.callCount == 1)
        #expect(tmdb.callCount == 0)
    }

    @Test("one dead source costs exactly one field")
    func partialAnswers() async {
        let failing = StubProvider(id: .radarr, supplies: [.availability], cost: .local,
                                   precedences: [.availability: 100]) { _ in
            throw MediaError.unreachable(.radarr)
        }
        let graph = MediaGraph(providers: [metadata(), failing])
        let snapshot = await graph.fetch(.tmdbMovie(603), fields: .card)

        #expect(snapshot.title?.title == "TMDB title")
        #expect(snapshot.availability == nil)
        #expect(snapshot.failures[.availability] == .unreachable(.radarr))
        #expect(snapshot.failures[.title] == nil)
    }

    @Test("an unconfigured provider is skipped, not failed")
    func unconfiguredIsSilent() async {
        let off = StubProvider(id: .radarr, supplies: [.availability],
                               isConfigured: false) { identity in
            Issue.record("an unconfigured provider must not be called")
            return MediaFragment(identity: identity)
        }
        let graph = MediaGraph(providers: [metadata(), off])
        let snapshot = await graph.fetch(.tmdbMovie(603), fields: [.title, .availability])

        #expect(snapshot.title != nil)
        #expect(snapshot.availability == nil)
    }

    @Test("the second identical query is served from cache")
    func cacheHit() async {
        let tmdb = metadata()
        let graph = MediaGraph(providers: [tmdb])
        _ = await graph.fetch(.tmdbMovie(603), fields: .title)
        _ = await graph.fetch(.tmdbMovie(603), fields: .title)

        #expect(tmdb.callCount == 1)
    }

    @Test("reload skips the cache; invalidate drops it")
    func cacheControl() async {
        let tmdb = metadata()
        let graph = MediaGraph(providers: [tmdb])
        _ = await graph.fetch(.tmdbMovie(603), fields: .title)
        _ = await graph.fetch(.tmdbMovie(603), fields: .title, policy: .reload)
        #expect(tmdb.callCount == 2)

        await graph.invalidate(.tmdbMovie(603))
        _ = await graph.fetch(.tmdbMovie(603), fields: .title)
        #expect(tmdb.callCount == 3)
    }

    @Test("concurrent callers make one request, not two")
    func coalescing() async {
        let slow = StubProvider(id: .tmdb, supplies: [.title]) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.title = TitleFacts(title: "The Matrix")
            return fragment
        }
        let graph = MediaGraph(providers: [slow])
        async let first = graph.fetch(.tmdbMovie(603), fields: .title)
        async let second = graph.fetch(.tmdbMovie(603), fields: .title)
        _ = await (first, second)

        #expect(slow.callCount == 1)
    }

    @Test("the debug report shows who answered what")
    func telemetryThroughTheGraph() async {
        let telemetry = MediaTelemetry(enabled: true)
        let graph = MediaGraph(providers: [metadata(), library()], telemetry: telemetry)
        _ = await graph.fetch(.tmdbMovie(603), fields: .card)

        let report = await telemetry.report()
        #expect(report.providers.contains { $0.provider == .radarr })
        let text = report.formatted()
        #expect(text.contains("radarr"))
        #expect(text.contains("availability"))
    }
}

@Suite("Sonarr and id resolution")
struct SonarrTests {
    private static let lookupJSON = """
    [
      {"id": 0, "title": "Wrong Show", "tvdbId": 111, "year": 2001},
      {"id": 8, "title": "Breaking Bad", "tvdbId": 81189, "year": 2008,
       "tmdbId": 1396, "imdbId": "tt0903747",
       "ratings": {"value": 9.2, "votes": 1533},
       "statistics": {"seasonCount": 5, "episodeFileCount": 62, "totalEpisodeCount": 62}}
    ]
    """

    private func sonarr(_ transport: HTTPTransport) -> SonarrProvider {
        SonarrProvider(credentials: .init(baseURL: URL(string: "http://nas.local:8989"),
                                          apiKey: "abc"),
                       transport: transport)
    }

    @Test("the record's own tvdb id decides the match, not the result order")
    func picksTheProvenMatch() async throws {
        let transport = FakeTransport(json: Self.lookupJSON)
        let identity = MediaIdentity(kind: .series, ids: [.tmdbSeries(1396), .tvdb(81189)])
        let fragment = try await sonarr(transport).fetch(identity, fields: [.availability, .title])

        #expect(fragment.title?.title == "Breaking Bad")
        #expect(fragment.availability?.owned == true)
        #expect(fragment.availability?.sources == ["Sonarr"])
        #expect(fragment.identity.contains(.arr(.sonarr, 8)))
    }

    @Test("TheTVDB's score comes through labelled as TheTVDB's")
    func tvdbRatings() async throws {
        let transport = FakeTransport(json: Self.lookupJSON)
        let identity = MediaIdentity(kind: .series, ids: [.tmdbSeries(1396), .tvdb(81189)])
        let fragment = try await sonarr(transport).fetch(identity, fields: .ratings)

        #expect(fragment.ratings?.value(for: .tvdb) == 9.2)
        #expect(fragment.ratings?.scores.first?.voteCount == 1533)
        // Never silently folded into somebody else's number.
        #expect(fragment.ratings?.value(for: .tmdb) == nil)
    }

    @Test("a series ends up with both TMDB's and TheTVDB's score")
    func bothServicesSurvive() async {
        let tmdb = StubProvider(id: .tmdb, supplies: [.ratings], cost: .remote,
                                precedences: [.ratings: 50]) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.ratings = Ratings(scores: [.init(service: .tmdb, value: 8.9)])
            return fragment
        }
        let graph = MediaGraph(providers: [tmdb, sonarr(FakeTransport(json: Self.lookupJSON))],
                               resolvers: [TMDBIdentityResolver(
                                   apiKey: "k", transport: FakeTransport(json: #"{"tvdb_id": 81189}"#))])
        let snapshot = await graph.fetch(.tmdbSeries(1396), fields: .ratings)

        #expect(snapshot.ratings?.value(for: .tvdb) == 9.2)
        #expect(snapshot.ratings?.value(for: .tmdb) == 8.9)
    }

    @Test("without a TVDB id Sonarr is not asked at all")
    func needsTVDB() async throws {
        let transport = FakeTransport(json: Self.lookupJSON)
        let provider = sonarr(transport)
        #expect(!provider.canAnswer(.tmdbSeries(1396)))
        let fragment = try await provider.fetch(.tmdbSeries(1396), fields: .availability)
        #expect(fragment.populated.isEmpty)
        #expect(transport.callCount == 0)
    }

    @Test("the graph resolves tmdb → tvdb so Sonarr can answer")
    func graphResolvesBeforePlanning() async {
        let externalIDs = FakeTransport(json: #"{"tvdb_id": 81189}"#)
        let lookup = FakeTransport(json: Self.lookupJSON)
        let graph = MediaGraph(providers: [sonarr(lookup)],
                               resolvers: [TMDBIdentityResolver(apiKey: "k", transport: externalIDs)])

        let snapshot = await graph.fetch(.tmdbSeries(1396), fields: .availability)

        #expect(externalIDs.callCount == 1)
        #expect(lookup.callCount == 1)
        #expect(snapshot.availability?.owned == true)
        #expect(snapshot.provenance[.availability]?.provider == .sonarr)
        #expect(snapshot.identity.contains(.tvdb(81189)))
    }

    @Test("a crossing is resolved once, then remembered")
    func resolutionIsCached() async throws {
        let externalIDs = FakeTransport(json: #"{"tvdb_id": 81189}"#)
        let resolver = TMDBIdentityResolver(apiKey: "k", transport: externalIDs)
        _ = try await resolver.resolve(.tmdbSeries(1396), into: .tvdb)
        _ = try await resolver.resolve(.tmdbSeries(1396), into: .tvdb)
        #expect(externalIDs.callCount == 1)
    }

    @Test("kind gating survives dispatch through `any MediaProvider`")
    func kindGatingIsDynamicallyDispatched() async {
        // `canAnswer` is a protocol REQUIREMENT: as an extension-only method
        // it dispatched statically here and Radarr was planned for series.
        let transport = FakeTransport(json: "{}")
        let radarr = RadarrProvider(
            credentials: .init(baseURL: URL(string: "http://nas.local:7878"), apiKey: "abc"),
            transport: transport)
        let graph = MediaGraph(providers: [radarr])
        _ = await graph.fetch(.tmdbSeries(1396), fields: .availability)
        #expect(transport.callCount == 0)
    }

    @Test("a series Radarr can't answer doesn't stop Sonarr answering")
    func movieProviderStandsAside() async {
        let radarr = RadarrProvider(
            credentials: .init(baseURL: URL(string: "http://nas.local:7878"), apiKey: "abc"),
            transport: FakeTransport([]))
        let graph = MediaGraph(providers: [radarr, sonarr(FakeTransport(json: Self.lookupJSON))],
                               resolvers: [TMDBIdentityResolver(
                                   apiKey: "k", transport: FakeTransport(json: #"{"tvdb_id": 81189}"#))])
        let snapshot = await graph.fetch(.tmdbSeries(1396), fields: .availability)
        #expect(snapshot.availability?.sources == ["Sonarr"])
    }
}

@Suite("Media server")
struct MediaServerTests {
    @Test("Plex guids map to the right id space, old and new shapes")
    func plexGuids() {
        #expect(MediaServerProvider.plexGuid("tmdb://603", isShow: false) == .tmdbMovie(603))
        // The same number names a different work for a show.
        #expect(MediaServerProvider.plexGuid("tmdb://1396", isShow: true) == .tmdbSeries(1396))
        #expect(MediaServerProvider.plexGuid("tvdb://81189", isShow: true) == .tvdb(81189))
        #expect(MediaServerProvider.plexGuid("imdb://tt0133093", isShow: false) == .imdb("tt0133093"))
        // Legacy agent form, with its query string.
        #expect(MediaServerProvider.plexGuid("com.plexapp.agents.themoviedb://603?lang=en",
                                             isShow: false) == .tmdbMovie(603))
        #expect(MediaServerProvider.plexGuid("local://12345", isShow: false) == nil)
        #expect(MediaServerProvider.plexGuid(nil, isShow: false) == nil)
    }

    @Test("a Plex sweep yields poster, backdrop and logo")
    func plexSweep() async throws {
        let sections = """
        {"MediaContainer": {"Directory": [{"key": "1", "type": "movie"},
                                          {"key": "9", "type": "photo"}]}}
        """
        let items = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "71282", "title": "The Matrix", "year": 1999,
           "thumb": "/library/metadata/71282/thumb/1", "art": "/library/metadata/71282/art/1",
           "viewCount": 1, "Guid": [{"id": "tmdb://603"}, {"id": "imdb://tt0133093"}],
           "Image": [{"type": "coverPoster", "url": "/x"},
                     {"type": "clearLogo", "url": "/library/metadata/71282/clearLogo/1"}]}
        ]}}
        """
        let transport = FakeTransport([
            HTTPResponse(status: 200, data: Data(sections.utf8)),
            HTTPResponse(status: 200, data: Data(items.utf8)),
        ])
        let provider = MediaServerProvider(flavor: .plex,
                                           baseURL: URL(string: "https://plex.example/"),
                                           token: "t", transport: transport)
        let titles = try await provider.titles()
        let matrix = try #require(titles[603])

        #expect(matrix.artwork.poster?.absoluteString == "https://plex.example/library/metadata/71282/thumb/1")
        #expect(matrix.artwork.backdrop?.absoluteString == "https://plex.example/library/metadata/71282/art/1")
        #expect(matrix.artwork.logo?.absoluteString == "https://plex.example/library/metadata/71282/clearLogo/1")
        #expect(matrix.watched)
        #expect(matrix.ids.contains(.imdb("tt0133093")))
        // The photo library is not asked for: two calls, not three.
        #expect(transport.callCount == 2)
    }

    @Test("the sweep happens once, however many titles ask")
    func sweepIsShared() async {
        let sections = #"{"MediaContainer": {"Directory": [{"key": "1", "type": "movie"}]}}"#
        let items = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "A", "thumb": "/a", "Guid": [{"id": "tmdb://603"}]}]}}
        """
        let transport = FakeTransport([
            HTTPResponse(status: 200, data: Data(sections.utf8)),
            HTTPResponse(status: 200, data: Data(items.utf8)),
        ])
        let provider = MediaServerProvider(flavor: .plex,
                                           baseURL: URL(string: "https://plex.example"),
                                           token: "t", transport: transport)
        let graph = MediaGraph(providers: [provider])
        _ = await graph.fetch(.tmdbMovie(603), fields: [.artwork, .availability])
        _ = await graph.fetch(.tmdbMovie(604), fields: [.artwork, .availability], policy: .reload)

        #expect(transport.callCount == 2)
    }

    @Test("Jellyfin items become artwork URLs with their tags")
    func jellyfinSweep() async throws {
        let payload = """
        {"Items": [
          {"Id": "abc", "Name": "Breaking Bad", "Type": "Series", "ProductionYear": 2008,
           "ProviderIds": {"Tmdb": "1396", "Tvdb": "81189", "Imdb": "tt0903747"},
           "ImageTags": {"Primary": "p1", "Logo": "l1"},
           "BackdropImageTags": ["b1"],
           "UserData": {"Played": true, "PlayedPercentage": 100}}
        ]}
        """
        let transport = FakeTransport(json: payload)
        let provider = MediaServerProvider(flavor: .jellyfin,
                                           baseURL: URL(string: "https://jf.example"),
                                           token: "t", userID: "u1", transport: transport)
        let titles = try await provider.titles()
        let show = try #require(titles[1396])

        #expect(show.ids.contains(.tmdbSeries(1396)))
        #expect(show.ids.contains(.tvdb(81189)))
        #expect(show.artwork.poster?.absoluteString == "https://jf.example/Items/abc/Images/Primary?tag=p1")
        #expect(show.artwork.backdrop?.absoluteString == "https://jf.example/Items/abc/Images/Backdrop/0?tag=b1")
        #expect(show.artwork.logo?.absoluteString == "https://jf.example/Items/abc/Images/Logo?tag=l1")
        #expect(show.watched)
        // Play state is per user: the user-scoped path is the one asked for.
        #expect(transport.requests.first?.url?.path().hasPrefix("/Users/u1/Items") == true)
    }

    @Test("a title the server doesn't have gets no artwork, only a plain no")
    func unknownTitle() async throws {
        let sections = #"{"MediaContainer": {"Directory": [{"key": "1", "type": "movie"}]}}"#
        let items = #"{"MediaContainer": {"Metadata": []}}"#
        let transport = FakeTransport([
            HTTPResponse(status: 200, data: Data(sections.utf8)),
            HTTPResponse(status: 200, data: Data(items.utf8)),
        ])
        let provider = MediaServerProvider(flavor: .plex,
                                           baseURL: URL(string: "https://plex.example"),
                                           token: "t", transport: transport)
        let fragment = try await provider.fetch(.tmdbMovie(603), fields: [.artwork, .availability])
        #expect(fragment.artwork == nil)          // …so TMDB's still wins the merge
        #expect(fragment.availability?.owned == false)
    }
}

@Suite("Artwork sizing")
struct ArtworkSizingTests {
    private let base = URL(string: "https://plex.example")!

    @Test("Plex sizing moves the path into the transcoder's url parameter")
    func plexTranscode() throws {
        let art = URL(string: "https://plex.example/library/metadata/1/thumb/2")!
        let sized = try #require(MediaServerArtworkSizing.sized(art, flavor: .plex,
                                                               baseURL: base, width: 500))
        let items = try #require(URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(sized.path() == "/photo/:/transcode")
        #expect(items.first { $0.name == "width" }?.value == "500")
        #expect(items.first { $0.name == "url" }?.value == "/library/metadata/1/thumb/2")
        #expect(items.first { $0.name == "upscale" }?.value == "0")
    }

    @Test("the box matches the shape being asked for")
    func aspectDrivesTheBox() throws {
        let art = URL(string: "https://plex.example/library/metadata/1/art/2")!
        func height(_ aspect: MediaServerArtworkSizing.Aspect) throws -> String? {
            let sized = try #require(MediaServerArtworkSizing.sized(art, flavor: .plex,
                                                                    baseURL: base, width: 780,
                                                                    aspect: aspect))
            return URLComponents(url: sized, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "height" }?.value
        }
        // A 16:9 backdrop in a poster-shaped box comes back twice the size.
        #expect(try height(.poster) == "1170")
        #expect(try height(.wide) == "438")
    }

    @Test("Jellyfin sizing is one extra parameter, and is not applied twice")
    func jellyfinMaxWidth() throws {
        let art = URL(string: "https://jf.example/Items/a/Images/Primary?tag=t")!
        let jf = URL(string: "https://jf.example")!
        let sized = try #require(MediaServerArtworkSizing.sized(art, flavor: .jellyfin,
                                                                baseURL: jf, width: 500))
        #expect(sized.absoluteString.contains("maxWidth=500"))
        let again = try #require(MediaServerArtworkSizing.sized(sized, flavor: .jellyfin,
                                                                baseURL: jf, width: 300))
        #expect(again == sized)
    }

    @Test("a URL that isn't the server's is left alone")
    func foreignURLsUntouched() {
        let tmdb = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
        #expect(MediaServerArtworkSizing.sized(tmdb, flavor: .plex, baseURL: base, width: 500) == nil)
    }
}

@Suite("Catalog queries")
struct CatalogTests {
    private static let page = """
    {"page": 1, "total_pages": 42, "total_results": 830, "results": [
      {"id": 603, "title": "The Matrix", "release_date": "1999-03-30",
       "poster_path": "/p.jpg", "backdrop_path": "/b.jpg",
       "vote_average": 8.2, "vote_count": 25000, "overview": "…"},
      {"id": 1396, "name": "Breaking Bad", "media_type": "tv",
       "first_air_date": "2008-01-20", "vote_average": 8.9}
    ]}
    """

    private func provider(_ transport: HTTPTransport) -> TMDBProvider {
        TMDBProvider(apiKey: "k", region: "PL", transport: transport)
    }

    @Test("a list endpoint's summaries arrive as snapshots, not bare ids")
    func summariesBecomeSnapshots() async throws {
        let transport = FakeTransport(json: Self.page)
        let result = try await provider(transport).catalog(
            MediaCatalogQuery(.trending(window: .week), kind: .movie))

        #expect(result.items.count == 2)
        let matrix = try #require(result.items.first)
        #expect(matrix.title?.title == "The Matrix")
        #expect(matrix.title?.year == 1999)
        #expect(matrix.ratings?.value(for: .tmdb) == 8.2)
        #expect(matrix.artwork?.poster?.absoluteString.hasSuffix("/p.jpg") == true)
        #expect(matrix.provenance[.title]?.provider == .tmdb)
        // The page's own `media_type` wins over the query's default kind.
        #expect(result.items[1].identity.kind == .series)
        #expect(result.totalPages == 42)
        #expect(result.hasMore)
    }

    @Test("discover turns the filter into TMDB's parameters")
    func discoverFilter() async throws {
        let transport = FakeTransport(json: Self.page)
        var filter = MediaFilter()
        filter.genreIDs = [878, 28]
        filter.yearRange = 1990...1999
        filter.minRating = 7.5
        filter.maxRuntimeMinutes = 120
        filter.streamingProviderIDs = [8]
        _ = try await provider(transport).catalog(
            MediaCatalogQuery(.discover, kind: .movie, filter: filter,
                              sort: .rating, page: 2, region: "PL"))

        let url = try #require(transport.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("/discover/movie"))
        #expect(url.contains("with_genres=28,878"))
        #expect(url.contains("primary_release_date.gte=1990-01-01"))
        #expect(url.contains("primary_release_date.lte=1999-12-31"))
        #expect(url.contains("vote_average.gte=7.5"))
        #expect(url.contains("with_runtime.lte=120"))
        #expect(url.contains("with_watch_providers=8"))
        #expect(url.contains("watch_region=PL"))
        #expect(url.contains("sort_by=vote_average.desc"))
        #expect(url.contains("page=2"))
    }

    @Test("series browse uses the air-date fields, not the release ones")
    func seriesDates() async throws {
        let transport = FakeTransport(json: Self.page)
        var filter = MediaFilter()
        filter.yearRange = 2020...2020
        _ = try await provider(transport).catalog(
            MediaCatalogQuery(.discover, kind: .series, filter: filter))
        let url = try #require(transport.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("first_air_date.gte=2020-01-01"))
        #expect(!url.contains("primary_release_date"))
    }

    @Test("filters a curated shelf can't honour are reported, not dropped")
    func unappliedFiltersAreNamed() async throws {
        let transport = FakeTransport(json: Self.page)
        var filter = MediaFilter()
        filter.minRating = 8
        filter.genreIDs = [18]
        let result = try await provider(transport).catalog(
            MediaCatalogQuery(.curated(.popular), kind: .movie, filter: filter))
        #expect(Set(result.unappliedFilters) == ["rating", "genres"])
    }

    @Test("TMDB refuses the library intent instead of guessing")
    func libraryIsNotTMDBs() async {
        let tmdb = provider(FakeTransport([]))
        #expect(!tmdb.canServe(MediaCatalogQuery(.library(.all))))
        #expect(!tmdb.canServe(MediaCatalogQuery(.curated(.recentlyAdded))))
        // Nor is music.
        #expect(!tmdb.canServe(MediaCatalogQuery(.discover, kind: .album)))
    }

    @Test("the graph enriches a page from local providers only")
    func enrichment() async throws {
        let tmdb = provider(FakeTransport(json: Self.page))
        let library = StubProvider(id: .radarr, supplies: [.availability], cost: .local,
                                   precedences: [.availability: 100]) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.availability = Availability(owned: identity.tmdbID == 603,
                                                 sources: ["Radarr"])
            return fragment
        }
        let metered = StubProvider(id: "expensive", supplies: [.availability], cost: .metered) { _ in
            Issue.record("a metered provider must not be fanned out over a grid")
            return MediaFragment(identity: .tmdbMovie(0))
        }
        // The real regression: `.local` is not enough. Radarr is local and
        // still costs one HTTP lookup per title.
        let perTitle = StubProvider(id: .radarr, supplies: [.availability], cost: .local,
                                    answersFromIndex: false) { _ in
            Issue.record("a per-title provider must not be fanned out over a grid")
            return MediaFragment(identity: .tmdbMovie(0))
        }
        let graph = MediaGraph(providers: [tmdb, library, metered, perTitle])
        let page = try await graph.catalog(MediaCatalogQuery(.trending(window: .week), kind: .movie),
                                           enrich: .availability)

        #expect(page.items.first?.availability?.owned == true)
        #expect(library.callCount == 2)
    }

    @Test("the presence filter is applied by the graph, since no source can")
    func presenceFilter() async throws {
        let tmdb = provider(FakeTransport(json: Self.page))
        let library = StubProvider(id: "library", supplies: [.availability], cost: .free) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.availability = Availability(owned: identity.tmdbID == 603)
            return fragment
        }
        var filter = MediaFilter()
        filter.presence = .notOwned
        let graph = MediaGraph(providers: [tmdb, library])
        let page = try await graph.catalog(
            MediaCatalogQuery(.trending(window: .week), kind: .movie, filter: filter),
            enrich: .availability)

        #expect(page.items.count == 1)
        #expect(page.items.first?.identity.tmdbID == 1396)
    }

    @Test("the same browse twice is one request; reload asks again")
    func catalogCache() async throws {
        let transport = FakeTransport(json: Self.page)
        let graph = MediaGraph(providers: [provider(transport)])
        let query = MediaCatalogQuery(.curated(.topRated), kind: .movie)
        _ = try await graph.catalog(query)
        _ = try await graph.catalog(query)
        #expect(transport.callCount == 1)
        _ = try await graph.catalog(query, policy: .reload)
        #expect(transport.callCount == 2)
    }

    @Test("a filmography comes back from cast and crew together")
    func credits() async throws {
        let payload = """
        {"cast": [{"id": 603, "title": "The Matrix", "media_type": "movie"}],
         "crew": [{"id": 604, "title": "The Matrix Reloaded", "media_type": "movie"}]}
        """
        let transport = FakeTransport(json: payload)
        let page = try await provider(transport).catalog(MediaCatalogQuery(.credits(person: 6384)))
        #expect(page.items.count == 2)
        #expect(transport.requests.first?.url?.path().contains("combined_credits") == true)
    }
}

extension CatalogTests {
    @Test("switching the library filter doesn't re-ask the source")
    func presenceIsNotPartOfTheRequest() async throws {
        let transport = FakeTransport(json: """
        {"page": 1, "total_pages": 1, "results": [
          {"id": 603, "title": "The Matrix"}, {"id": 604, "title": "Reloaded"}]}
        """)
        let library = StubProvider(id: "library", supplies: [.availability], cost: .free) { identity in
            var fragment = MediaFragment(identity: identity)
            fragment.availability = Availability(owned: identity.tmdbID == 603)
            return fragment
        }
        let graph = MediaGraph(providers: [TMDBProvider(apiKey: "k", transport: transport), library])

        func browse(_ presence: MediaFilter.LibraryPresence) async throws -> Int {
            var filter = MediaFilter()
            filter.presence = presence
            return try await graph.catalog(
                MediaCatalogQuery(.discover, kind: .movie, filter: filter),
                enrich: .availability).items.count
        }

        #expect(try await browse(.any) == 2)
        #expect(try await browse(.owned) == 1)
        #expect(try await browse(.notOwned) == 1)
        // One page fetched, three answers derived from it.
        #expect(transport.callCount == 1)
    }
}

@Suite("Errors")
struct MediaErrorTests {
    @Test("failures read as sentences, not as Swift cases")
    func messagesAreForPeople() {
        // The browse that failed showed "unsupported(MediaKit.MediaField.title)".
        #expect(MediaError.unsupported(.title).errorDescription?.contains("MediaField") != true)
        #expect(MediaError.noSource("discover (movie) — configured: none")
            .errorDescription?.contains("No source") == true)
        #expect(MediaError.unauthorized(.tmdb).errorDescription?.contains("tmdb") == true)
    }

    @Test("a browse nobody can serve names what was asked and who was configured")
    func noSourceCarriesContext() async {
        let graph = MediaGraph(providers: [TMDBProvider(apiKey: "", transport: URLSessionTransport())])
        await #expect(throws: MediaError.self) {
            try await graph.catalog(MediaCatalogQuery(.discover, kind: .movie))
        }
        do {
            _ = try await graph.catalog(MediaCatalogQuery(.discover, kind: .movie))
        } catch let error as MediaError {
            guard case .noSource(let detail) = error else {
                Issue.record("expected .noSource, got \(error)")
                return
            }
            #expect(detail.contains("discover"))
            #expect(detail.contains("configured: none"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
