import Foundation
import Testing
@testable import ArrCore

/// The add-request bodies are `[String: Any]`, so nothing type-checks what goes
/// into them. That is where a rename stops being compiler-guarded: when
/// `SearchResult.id` became the row's identity *string* and the foreign key
/// moved to `externalId`, `"tmdbId": result.id` kept compiling and started
/// posting `"radarr:tmdb:550"`. Radarr answered
/// `The JSON value could not be converted to System.Int32. Path: $.tmdbId`,
/// and the only place that could have caught it earlier is a test that reads
/// the bytes actually sent.
///
/// So: one test per add path, each decoding the real POST body.
private final class AddStubState: @unchecked Sendable {
    var bodies: [String: Any] = [:]
    var lastPath = ""
}

private final class AddStub: URLProtocol, @unchecked Sendable {
    static let state = AddStubState()
    static let host = "add-body.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lastPath = request.url?.path ?? ""
        // URLProtocol strips httpBody for uploads; httpBodyStream carries it.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.state.bodies = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let url = request.url ?? URL(string: "about:blank")!
        let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id": 7}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Add request bodies", .serialized)
struct AddRequestBodyTests {

    private func client(_ source: QueueItem.Source) -> SearchClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AddStub.self]
        return SearchClient(
            config: ServiceConfig(enabled: true, baseURL: "http://\(AddStub.host):7878",
                                  apiKey: "k", username: "", password: ""),
            source: source, session: URLSession(configuration: cfg))
    }

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

    @Test("Adding a movie posts tmdbId as a number, not the row's identity")
    func addMovieSendsNumericTMDBId() async throws {
        AddStub.state.bodies = [:]
        _ = try await client(.radarr).addMovie(
            movieRow(), qualityProfileId: 1, rootFolderPath: "/movies",
            monitor: .movieOnly, searchOnAdd: false)

        let posted = AddStub.state.bodies["tmdbId"]
        #expect(posted as? Int == 550)
        // The failure this guards against is a *string* that looks like an id.
        #expect(posted as? String == nil)
    }

    @Test("Adding a series posts tvdbId as a number")
    func addSeriesSendsNumericTVDBId() async throws {
        AddStub.state.bodies = [:]
        _ = try await client(.sonarr).addSeries(
            seriesRow(), qualityProfileId: 1, rootFolderPath: "/tv",
            monitor: .all, seriesType: .standard, seasonFolder: true, searchOnAdd: false)

        let posted = AddStub.state.bodies["tvdbId"]
        #expect(posted as? Int == 74875)
        #expect(posted as? String == nil)
    }

    /// Lidarr is the one path whose foreign key really is a string (an MBID),
    /// so this pins the difference rather than assuming every arr is numeric.
    @Test("Adding an artist posts the MusicBrainz id as a string")
    func addArtistSendsStringForeignId() async throws {
        AddStub.state.bodies = [:]
        let artist = SearchResult(
            externalId: 0, foreignId: "83d91898-7763-47d7-b03b-b92132375c47",
            title: "Pink Floyd", subtitle: nil, year: nil, rating: nil,
            imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: nil, runtime: nil,
            genres: [], network: nil, certification: nil, posterURL: nil, source: .lidarr)

        _ = try await client(.lidarr).addArtist(
            artist, qualityProfileId: 1, metadataProfileId: 1,
            rootFolderPath: "/music", searchOnAdd: false)

        #expect(AddStub.state.bodies["foreignArtistId"] as? String
                == "83d91898-7763-47d7-b03b-b92132375c47")
    }
}
