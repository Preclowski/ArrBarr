import Testing
import Foundation
@testable import ArrCore

// MARK: - URL Protocol stub for shared session

/// Stubs URLSession.shared by registering globally (before first use in each test).
/// Keys responses by path prefix so multiple endpoints can coexist.
private final class LocalStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // Find the first matching handler by path prefix.
        let match = Self.handlers.first { path.hasPrefix($0.key) || path.contains($0.key) }
        let (status, body) = match?.value ?? (200, Data("[]".utf8))
        let url = request.url ?? URL(string: "about:blank")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { handlers = [:] }
}

// MARK: - Test suite

@Suite("LocalToolBackend", .serialized)
struct LocalToolBackendTests {

    private func sonarrConfig() -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://sonarr.local:8989", apiKey: "test-key",
                      username: "", password: "")
    }

    private func radarrConfig() -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://radarr.local:7878", apiKey: "test-key",
                      username: "", password: "")
    }

    private func backend() -> LocalToolBackend {
        LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig())
    }

    @Test("listTools returns 8 expected tool names")
    func listToolsReturns8Tools() async throws {
        let tools = try await backend().listTools()
        #expect(tools.count == 8)
        let names = Set(tools.map(\.name))
        let expected: Set<String> = [
            "sonarr_search",
            "radarr_search",
            "sonarr_get_series",
            "radarr_get_movies",
            "sonarr_get_calendar",
            "radarr_get_calendar",
            "sonarr_add_series",
            "radarr_add_movie",
        ]
        #expect(names == expected)
    }

    @Test("callTool unknown tool throws LocalToolError.unknownTool")
    func unknownToolThrows() async throws {
        await #expect(throws: LocalToolError.unknownTool("bogus")) {
            _ = try await backend().callTool(name: "bogus", arguments: .object([:]))
        }
    }

    @Test("callTool sonarr_search when sonarr not configured returns informative string")
    func sonarrSearchNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: .empty, radarr: radarrConfig())
        let result = try await b.callTool(name: "sonarr_search", arguments: .object(["query": .string("Severance")]))
        #expect(result == "Sonarr is not configured.")
    }

    @Test("callTool radarr_search when radarr not configured returns informative string")
    func radarrSearchNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: .empty)
        let result = try await b.callTool(name: "radarr_search", arguments: .object(["query": .string("Dune")]))
        #expect(result == "Radarr is not configured.")
    }

    @Test("callTool sonarr_search empty query returns prompt string")
    func sonarrSearchEmptyQuery() async throws {
        let result = try await backend().callTool(name: "sonarr_search", arguments: .object([:]))
        #expect(result == "Please provide a search query.")
    }

    @Test("callTool sonarr_search stubs HTTP and returns formatted results")
    func sonarrSearchFormatted() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }

        let json = """
        [{"tvdbId":369232,"title":"Severance","year":2022,"images":[],
          "statistics":{"seasonCount":2},"ratings":{"value":8.5},"genres":[]}]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/series/lookup"] = (200, json)

        let result = try await backend().callTool(
            name: "sonarr_search",
            arguments: .object(["query": .string("Severance")])
        )
        #expect(result.contains("Severance"))
        #expect(result.contains("2022"))
    }

    @Test("callTool sonarr_get_calendar stubs HTTP and returns formatted calendar")
    func sonarrCalendarFormatted() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }

        let json = """
        [{"id":1,"episodeNumber":1,"seasonNumber":1,"title":"Pilot",
          "airDateUtc":"2025-06-01T19:00:00Z","hasFile":false,
          "series":{"id":10,"title":"My Show","images":[]}}]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/calendar"] = (200, json)

        let result = try await backend().callTool(name: "sonarr_get_calendar", arguments: .object([:]))
        #expect(result.contains("My Show"))
        #expect(result.hasPrefix("Upcoming releases:"))
    }

    @Test("callTool sonarr_get_series stubs HTTP and returns library with filter")
    func sonarrGetSeriesFiltered() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }

        let json = """
        [
          {"id":1,"tvdbId":369232,"title":"Severance","year":2022,"status":"continuing","monitored":true},
          {"id":2,"tvdbId":121361,"title":"Game of Thrones","year":2011,"status":"ended","monitored":false}
        ]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/series"] = (200, json)

        let result = try await backend().callTool(
            name: "sonarr_get_series",
            arguments: .object(["query": .string("severance")])
        )
        #expect(result.contains("Severance"))
        #expect(result.contains("tvdbId=369232"))
        #expect(!result.contains("Game of Thrones"))
    }

    @Test("callTool radarr_get_movies stubs HTTP and returns library with filter")
    func radarrGetMoviesFiltered() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }

        let json = """
        [
          {"id":1,"tmdbId":361743,"title":"Colony","year":2013,"hasFile":true,"monitored":true},
          {"id":2,"tmdbId":12345,"title":"Dune","year":2021,"hasFile":false,"monitored":true}
        ]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/movie"] = (200, json)

        let result = try await backend().callTool(
            name: "radarr_get_movies",
            arguments: .object(["query": .string("colony")])
        )
        #expect(result.contains("Colony"))
        #expect(result.contains("tmdbId=361743"))
        #expect(result.contains("downloaded"))
        #expect(!result.contains("Dune"))
    }

    @Test("callTool radarr_get_movies when radarr not configured returns informative string")
    func radarrGetMoviesNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: .empty)
        let result = try await b.callTool(name: "radarr_get_movies", arguments: .object([:]))
        #expect(result == "Radarr is not configured.")
    }
}
