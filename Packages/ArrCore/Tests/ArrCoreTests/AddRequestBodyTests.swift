import Foundation
import MediaKit
import Testing
@testable import ArrCore

/// The add-request bodies used to be `[String: Any]`, so nothing type-checked what
/// went into them. That is where a rename stops being compiler-guarded: when
/// `SearchResult.id` became the row's identity *string* and the foreign key
/// moved to `externalId`, `"tmdbId": result.id` kept compiling and started
/// posting `"radarr:tmdb:550"`. Radarr answered
/// `The JSON value could not be converted to System.Int32. Path: $.tmdbId`,
/// and the only place that could have caught it earlier is a test that reads
/// the bytes actually sent.
///
/// So: one test per add path, each decoding the real POST body and pinning its whole shape.
private let addTransport = ScriptedTransport { _ in .init(status: 201, #"{"id": 7}"#) }

@Suite("Add request bodies", .serialized, .gateway(addTransport))
struct AddRequestBodyTests {

    private func client(_ source: QueueItem.Source) -> SearchClient {
        addTransport.reset()
        return SearchClient(
            config: ServiceConfig(enabled: true, baseURL: "http://add-body.test:7878",
                                  apiKey: "k", username: "", password: ""),
            source: source)
    }

    /// The add itself; a capability probe or the realtime hub's negotiate for the new instance may land around it.
    private var post: HTTPRequest? { addTransport.requests.last { $0.method == "POST" && !$0.operation.name.hasPrefix("realtime.") } }
    private var posted: [String: Any] { post?.jsonBody ?? [:] }
    private var postedPath: String { post?.url.path ?? "" }

    private func movieRow() -> SearchResult {
        SearchResult(externalId: 550, foreignId: "550", title: "Fight Club", subtitle: nil,
                     year: 1999, rating: nil, imdb: nil, rottenTomatoes: nil, metacritic: nil,
                     overview: nil, runtime: nil, genres: [], network: nil, certification: nil,
                     posterURL: nil, source: .radarr)
    }

    private func seriesRow() -> SearchResult {
        SearchResult(externalId: 74875, foreignId: "74875", title: "The Closer", subtitle: nil,
                     year: 2005, rating: nil, imdb: nil, rottenTomatoes: nil, metacritic: nil,
                     overview: nil, runtime: nil, genres: [], network: nil, certification: nil,
                     posterURL: nil, source: .sonarr, tmdbTVId: 1450)
    }

    private func sceneRow(foreignId: String) -> SearchResult {
        SearchResult(externalId: 1, foreignId: foreignId, title: "Scene", subtitle: nil,
                     year: 2020, rating: nil, imdb: nil, rottenTomatoes: nil, metacritic: nil,
                     overview: nil, runtime: nil, genres: [], network: nil, certification: nil,
                     posterURL: nil, source: .whisparr)
    }

    private func artistRow() -> SearchResult {
        SearchResult(externalId: 0, foreignId: "83d91898-7763-47d7-b03b-b92132375c47",
                     title: "Pink Floyd", subtitle: nil, year: nil, rating: nil,
                     imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: nil, runtime: nil,
                     genres: [], network: nil, certification: nil, posterURL: nil, source: .lidarr)
    }

    private func expectPosted(_ expected: [String: Any], path: String) {
        #expect(postedPath == path)
        #expect(NSDictionary(dictionary: posted) == NSDictionary(dictionary: expected))
    }

    @Test("Adding a movie posts tmdbId as a number, not the row's identity")
    func addMovieSendsNumericTMDBId() async throws {
        let id = try await client(.radarr).addMovie(
            movieRow(), qualityProfileId: 1, rootFolderPath: "/movies",
            monitor: .movieOnly, searchOnAdd: false)

        #expect(id == 7)
        #expect(posted["tmdbId"] as? Int == 550)
        // The failure this guards against is a *string* that looks like an id.
        #expect(posted["tmdbId"] as? String == nil)
        expectPosted([
            "tmdbId": 550, "title": "Fight Club", "qualityProfileId": 1, "rootFolderPath": "/movies",
            "monitored": true, "monitor": "movieOnly", "addOptions": ["searchForMovie": false],
        ], path: "/api/v3/movie")
    }

    @Test("Adding a series posts tvdbId as a number and the camelCase monitor mode")
    func addSeriesSendsNumericTVDBId() async throws {
        _ = try await client(.sonarr).addSeries(
            seriesRow(), qualityProfileId: 1, rootFolderPath: "/tv",
            monitor: .first, seriesType: .standard, seasonFolder: true, searchOnAdd: true)

        #expect(posted["tvdbId"] as? Int == 74875)
        #expect(posted["tvdbId"] as? String == nil)
        expectPosted([
            "tvdbId": 74875, "title": "The Closer", "qualityProfileId": 1, "rootFolderPath": "/tv",
            "monitored": true, "seriesType": "standard", "seasonFolder": true,
            "addOptions": ["monitor": "firstSeason", "searchForMissingEpisodes": true],
        ], path: "/api/v3/series")
    }

    @Test("Adding a scene posts tmdbId when it has one, the foreign id otherwise")
    func addSceneIdentity() async throws {
        _ = try await client(.whisparr).addScene(sceneRow(foreignId: "4242"), qualityProfileId: 2, rootFolderPath: "/scenes", searchOnAdd: true)
        expectPosted([
            "tmdbId": 4242, "title": "Scene", "qualityProfileId": 2, "rootFolderPath": "/scenes",
            "monitored": true, "monitor": "movieOnly", "addOptions": ["searchForMovie": true],
        ], path: "/api/v3/movie")

        _ = try await client(.whisparr).addScene(sceneRow(foreignId: "stash-abc"), qualityProfileId: 2, rootFolderPath: "/scenes", searchOnAdd: false)
        expectPosted([
            "foreignId": "stash-abc", "title": "Scene", "qualityProfileId": 2, "rootFolderPath": "/scenes",
            "monitored": true, "monitor": "movieOnly", "addOptions": ["searchForMovie": false],
        ], path: "/api/v3/movie")
    }

    /// Lidarr is the one path whose foreign key really is a string (an MBID),
    /// so this pins the difference rather than assuming every arr is numeric.
    @Test("Adding an artist posts the MusicBrainz id as a string")
    func addArtistSendsStringForeignId() async throws {
        _ = try await client(.lidarr).addArtist(
            artistRow(), qualityProfileId: 1, metadataProfileId: 3,
            rootFolderPath: "/music", searchOnAdd: false)

        #expect(posted["foreignArtistId"] as? String == "83d91898-7763-47d7-b03b-b92132375c47")
        expectPosted([
            "foreignArtistId": "83d91898-7763-47d7-b03b-b92132375c47", "artistName": "Pink Floyd",
            "qualityProfileId": 1, "metadataProfileId": 3, "rootFolderPath": "/music", "monitored": true,
            "addOptions": ["monitor": "all", "searchForMissingAlbums": false],
        ], path: "/api/v1/artist")
    }
}
