import Testing
import Foundation
@testable import ArrCore

// MARK: - URL Protocol stub for shared session

/// Stubs URLSession.shared by registering globally (before first use in each test).
/// Keys responses by path prefix so multiple endpoints can coexist.
private final class LocalStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: (Int, Data)] = [:]

    // Scoped to this suite's hosts. Answering every request — suites run in
    // parallel — serves other suites their neighbour's fixture, and the victim
    // sees impossible values (zero requests for a call it definitely made).
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".local") ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // Most-specific match wins. `dict.first` iterates in hash
        // order so when both "/api/v1/artist/lookup" and the looser
        // "/api/v1/artist" are registered, either could be returned
        // — which non-deterministically broke the lidarr_search test
        // when the looser handler with `[]` body came up first.
        // Sort handler keys by length descending and pick the first
        // that matches.
        let match = Self.handlers
            .sorted { $0.key.count > $1.key.count }
            .first { path.hasPrefix($0.key) || path.contains($0.key) }
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

    private func lidarrConfig() -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://lidarr.local:8686", apiKey: "test-key",
                      username: "", password: "")
    }

    private func backend() -> LocalToolBackend {
        LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig(), lidarr: lidarrConfig())
    }

    /// Runs `body` standing in for a user who taps Confirm.
    ///
    /// `callTool` refuses every tool outside `MCPToolWhitelist.readOnlyTools`
    /// unless a handler is bound, so a test that exercises a *mutating* tool's
    /// argument handling has to supply one. Approving with the arguments it was
    /// handed is what the chat confirm card does today.
    private func approvingConfirmation<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        let approve: ToolConfirmationHandler = { .approved($0.arguments) }
        return try await ToolConfirmationContext.$handler.withValue(approve) {
            try await body()
        }
    }

    @Test("listTools returns the full catalog when sonarr/radarr/lidarr are configured")
    func listToolsReturnsCatalog() async throws {
        let tools = try await backend().listTools()
        let names = Set(tools.map(\.name))
        // The `*_add_*` tools were removed — the add flow is now
        // UI-driven via SearchAddPanel; chat tools surface results
        // as tappable cards instead of adding directly. The
        // lifecycle / season-search tools, `suggest_titles`, and
        // `arr_health` were added since the original `count == 12`
        // assertion. Pin the test to the current catalog so a future
        // tool addition surfaces here intentionally.
        let expected: Set<String> = [
            // Sonarr
            "sonarr_search",
            "sonarr_get_series",
            "sonarr_monitor_season",
            "sonarr_search_episodes",
            // Radarr
            "radarr_search",
            "radarr_get_movies",
            "radarr_search_movie",
            // Lidarr
            "lidarr_search",
            "lidarr_get_artists",
            "lidarr_get_artist_albums",
            "lidarr_monitor_album",
            "lidarr_search_album",
            // Cross-cutting (gated on configured arrs)
            "check_titles",
            "suggest_titles",
            "discover_in_quiz",
            "get_calendar",         // unified calendar (was per-arr *_get_calendar)
            "health",               // was arr_health, now incl. download clients
            "list_download_queue",
            "get_title_details",    // single-title overview + optional cast
            "custom_formats",       // merged list_custom_formats + describe_format
        ]
        #expect(names == expected)
        #expect(tools.count == expected.count)
    }

    @Test("listTools omits unconfigured arrs")
    func listToolsGatesOnConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: .empty, lidarr: .empty)
        let tools = try await b.listTools()
        let names = Set(tools.map(\.name))
        // Only sonarr_* tools — plus `suggest_titles` (gated on
        // sonarr-or-radarr-configured) and `arr_health` (gated on
        // any-arr-configured). These last two aren't prefixed by an
        // arr name because they're catalog-cutting.
        let crossCutting: Set<String> = ["check_titles", "suggest_titles", "discover_in_quiz", "get_calendar",
                                         "health", "list_download_queue", "get_title_details", "custom_formats"]
        #expect(names.subtracting(crossCutting).allSatisfy { $0.hasPrefix("sonarr_") })
        // 4 sonarr (calendar merged out) + check_titles + suggest_titles
        // + discover_in_quiz + get_calendar + health + list_download_queue
        // + get_title_details + custom_formats = 12
        #expect(tools.count == 12)
    }

    @Test("listTools includes TMDB tools when key set and matching arr configured")
    func listToolsIncludesTMDBWhenKeyed() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig(),
                                 lidarr: .empty, tmdbApiKey: "abc123")
        let names = Set(try await b.listTools().map(\.name))
        #expect(names.contains("tmdb_search_person"))
        #expect(names.contains("tmdb_discover_movies"))
        #expect(names.contains("tmdb_discover_series"))
    }

    @Test("listTools omits TMDB tools when key empty")
    func listToolsOmitsTMDBWithoutKey() async throws {
        let names = Set(try await backend().listTools().map(\.name))
        #expect(!names.contains(where: { $0.hasPrefix("tmdb_") }))
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
        let output = try await b.callTool(name: "sonarr_search", arguments: .object(["query": .string("Severance")]))
        #expect(output.text == "Sonarr is not configured.")
        #expect(output.rich == nil)
    }

    @Test("callTool radarr_search when radarr not configured returns informative string")
    func radarrSearchNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: .empty)
        let output = try await b.callTool(name: "radarr_search", arguments: .object(["query": .string("Dune")]))
        #expect(output.text == "Radarr is not configured.")
        #expect(output.rich == nil)
    }

    @Test("callTool sonarr_monitor_season grabs EVERY season in seasonNumbers, not just the first")
    func sonarrMonitorMultipleSeasons() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        // V5 season-monitor PUT + command POST both accepted.
        LocalStubProtocol.handlers["/api/v5/series"] = (200, Data("{}".utf8))
        LocalStubProtocol.handlers["/api/v3/command"] = (201, Data("{\"id\":1}".utf8))

        let b = backend()
        let output = try await approvingConfirmation {
            try await b.callTool(
                name: "sonarr_monitor_season",
                arguments: .object([
                    "seriesId": .number(241),
                    "seasonNumbers": .array([.number(10), .number(11)]),
                ])
            )
        }
        #expect(output.text.hasPrefix("OK"))
        // Both requested seasons must be reported — the old single-int
        // schema silently dropped season 11.
        #expect(output.text.contains("10"))
        #expect(output.text.contains("11"))
    }

    @Test("callTool sonarr_monitor_season still accepts a legacy single seasonNumber")
    func sonarrMonitorSingleSeasonLegacy() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        LocalStubProtocol.handlers["/api/v5/series"] = (200, Data("{}".utf8))
        LocalStubProtocol.handlers["/api/v3/command"] = (201, Data("{\"id\":1}".utf8))

        let b = backend()
        let output = try await approvingConfirmation {
            try await b.callTool(
                name: "sonarr_monitor_season",
                arguments: .object([
                    "seriesId": .number(241),
                    "seasonNumber": .number(3),
                ])
            )
        }
        #expect(output.text.hasPrefix("OK"))
        #expect(output.text.contains("3"))
    }

    @Test("callTool refuses a destructive tool when no confirmation handler is bound")
    func destructiveToolWithoutHandlerRefuses() async throws {
        // No `approvingConfirmation` wrapper: this is the fail-closed path a
        // call site hits when it forgets to bind a handler. Nothing is stubbed
        // because nothing should reach the network.
        await #expect(throws: LocalToolError.confirmationUnavailable("sonarr_monitor_season")) {
            _ = try await backend().callTool(
                name: "sonarr_monitor_season",
                arguments: .object(["seriesId": .number(241), "seasonNumber": .number(1)])
            )
        }
    }

    @Test("callTool runs a read-only tool with no handler bound")
    func readOnlyToolNeedsNoHandler() async throws {
        // The other half of the gate: gating everything would be safe and
        // useless. `sonarr_search` is on the allowlist, so an unattended caller
        // still gets it — here it reaches the not-configured short-circuit,
        // which only executes if the gate let it through.
        let b = LocalToolBackend(sonarr: .empty, radarr: radarrConfig())
        let output = try await b.callTool(name: "sonarr_search", arguments: .object(["query": .string("Severance")]))
        #expect(output.text == "Sonarr is not configured.")
    }

    @Test("callTool sonarr_search empty query returns prompt string")
    func sonarrSearchEmptyQuery() async throws {
        let output = try await backend().callTool(name: "sonarr_search", arguments: .object([:]))
        #expect(output.text == "Please provide a search query.")
        #expect(output.rich == nil)
    }

    @Test("callTool sonarr_search stubs HTTP and returns formatted results with rich payload")
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

        let output = try await backend().callTool(
            name: "sonarr_search",
            arguments: .object(["query": .string("Severance")])
        )
        #expect(output.text.contains("Severance"))
        #expect(output.text.contains("2022"))
        // Rich payload must be populated with searchSeriesResults
        if case .searchSeriesResults(let results) = output.rich {
            #expect(results.count == 1)
            #expect(results[0].title == "Severance")
        } else {
            Issue.record("Expected .searchSeriesResults rich payload")
        }
    }

    @Test("callTool radarr_search returns searchMovieResults rich payload")
    func radarrSearchRichPayload() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }

        let json = """
        [{"tmdbId":361743,"title":"Colony","year":2013,"images":[],"genres":[],"ratings":{"tmdb":{"value":7.2}}}]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/movie/lookup"] = (200, json)

        let output = try await backend().callTool(
            name: "radarr_search",
            arguments: .object(["query": .string("Colony")])
        )
        #expect(output.text.contains("Colony"))
        if case .searchMovieResults(let results) = output.rich {
            #expect(results.count == 1)
            #expect(results[0].title == "Colony")
        } else {
            Issue.record("Expected .searchMovieResults rich payload")
        }
    }

    @Test("callTool get_calendar(service:sonarr) stubs HTTP and returns formatted calendar with rich payload")
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

        let output = try await backend().callTool(
            name: "get_calendar",
            arguments: .object(["service": .string("sonarr")])
        )
        #expect(output.text.contains("My Show"))
        #expect(output.text.hasPrefix("Upcoming releases:"))
        if case .calendar(let items) = output.rich {
            #expect(items.count == 1)
        } else {
            Issue.record("Expected .calendar rich payload")
        }
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

        let output = try await backend().callTool(
            name: "sonarr_get_series",
            arguments: .object(["query": .string("severance")])
        )
        #expect(output.text.contains("Severance"))
        #expect(output.text.contains("tvdbId=369232"))
        #expect(!output.text.contains("Game of Thrones"))
        if case .librarySeries(let recs) = output.rich {
            #expect(recs.count == 1)
        } else {
            Issue.record("Expected .librarySeries rich payload")
        }
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

        let output = try await backend().callTool(
            name: "radarr_get_movies",
            arguments: .object(["query": .string("colony")])
        )
        #expect(output.text.contains("Colony"))
        #expect(output.text.contains("tmdbId=361743"))
        #expect(output.text.contains("downloaded"))
        #expect(!output.text.contains("Dune"))
        if case .libraryMovies(let recs) = output.rich {
            #expect(recs.count == 1)
        } else {
            Issue.record("Expected .libraryMovies rich payload")
        }
    }

    @Test("callTool radarr_get_movies when radarr not configured returns informative string")
    func radarrGetMoviesNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: .empty)
        let output = try await b.callTool(name: "radarr_get_movies", arguments: .object([:]))
        #expect(output.text == "Radarr is not configured.")
        #expect(output.rich == nil)
    }

    // MARK: - Lidarr

    @Test("callTool lidarr_search when lidarr not configured returns informative string")
    func lidarrSearchNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig(), lidarr: .empty)
        let output = try await b.callTool(name: "lidarr_search", arguments: .object(["query": .string("Radiohead")]))
        #expect(output.text == "Lidarr is not configured.")
        #expect(output.rich == nil)
    }

    @Test("callTool lidarr_search empty query returns prompt string")
    func lidarrSearchEmptyQuery() async throws {
        let lidarrConfig = ServiceConfig(enabled: true, baseURL: "http://lidarr.local:8686", apiKey: "test-key",
                                         username: "", password: "")
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig(), lidarr: lidarrConfig)
        let output = try await b.callTool(name: "lidarr_search", arguments: .object([:]))
        #expect(output.text == "Please provide a search query.")
        #expect(output.rich == nil)
    }

    @Test("callTool lidarr_search stubs HTTP and returns formatted results with rich payload")
    func lidarrSearchFormatted() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }

        // Text terms go through Lidarr's mixed `/search` endpoint (entries
        // wrapping either an artist or an album) — see SearchClient.lookup.
        let json = """
        [{"foreignId":"a74b1b7f-71a5-4011-9441-d0b5e4122711",
          "artist":{"foreignArtistId":"a74b1b7f-71a5-4011-9441-d0b5e4122711","artistName":"Radiohead",
          "disambiguation":"","overview":"Alternative rock band","genres":["Alternative"],
          "images":[],"ratings":{"value":8.9}}}]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v1/search"] = (200, json)
        // library fetch returns empty
        LocalStubProtocol.handlers["/api/v1/artist"] = (200, Data("[]".utf8))

        let lidarrConfig = ServiceConfig(enabled: true, baseURL: "http://lidarr.local:8686", apiKey: "test-key",
                                         username: "", password: "")
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig(), lidarr: lidarrConfig)
        let output = try await b.callTool(
            name: "lidarr_search",
            arguments: .object(["query": .string("Radiohead")])
        )
        #expect(output.text.contains("Radiohead"))
        #expect(output.text.contains("foreignArtistId="))
        if case .searchArtistResults(let results) = output.rich {
            #expect(results.count == 1)
            #expect(results[0].title == "Radiohead")
            #expect(results[0].foreignId == "a74b1b7f-71a5-4011-9441-d0b5e4122711")
            #expect(results[0].source == .lidarr)
        } else {
            Issue.record("Expected .searchArtistResults rich payload")
        }
    }

    @Test("unifyLidarr produces stable id and correct source")
    func unifyLidarrHappyPath() {
        let record = LidarrLookupRecord(
            foreignArtistId: "a74b1b7f-71a5-4011-9441-d0b5e4122711",
            artistName: "Radiohead",
            disambiguation: "UK band",
            overview: "Alt rock",
            images: nil,
            ratings: LidarrLookupRatings(value: 8.9),
            genres: ["Alternative"]
        )
        let result = SearchClient.unifyLidarr(record, baseURL: "http://lidarr.local:8686")
        #expect(result != nil)
        #expect(result?.title == "Radiohead")
        #expect(result?.subtitle == "UK band")
        #expect(result?.foreignId == "a74b1b7f-71a5-4011-9441-d0b5e4122711")
        #expect(result?.source == .lidarr)
        #expect(result?.year == nil)
        // id is hashed from foreignArtistId — must be non-negative
        if let id = result?.externalId {
            #expect(id >= 0)
        }
    }

    @Test("callTool lidarr_get_artists when lidarr not configured returns informative string")
    func lidarrGetArtistsNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: sonarrConfig(), radarr: radarrConfig(), lidarr: .empty)
        let output = try await b.callTool(name: "lidarr_get_artists", arguments: .object([:]))
        #expect(output.text == "Lidarr is not configured.")
        #expect(output.rich == nil)
    }

    // MARK: - Title details

    @Test("get_title_details(radarr) returns overview + metadata, no cast by default")
    func titleDetailsMovie() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        LocalStubProtocol.handlers["/api/v3/movie/55"] = (200, Data("""
        {"id":55,"tmdbId":603,"title":"The Matrix","year":1999,"runtime":136,
         "genres":["Action","Sci-Fi"],"overview":"A hacker learns the truth.","status":"released"}
        """.utf8))

        let output = try await backend().callTool(
            name: "get_title_details",
            arguments: .object(["service": .string("radarr"), "id": .number(55)])
        )
        #expect(output.text.contains("The Matrix (1999)"))
        #expect(output.text.contains("A hacker learns the truth."))
        #expect(output.text.contains("136 min"))
        // No include_cast → no Cast section.
        #expect(!output.text.contains("Cast"))
    }

    @Test("get_title_details movie cast comes from Radarr /credit (no TMDB key)")
    func titleDetailsMovieCast() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        LocalStubProtocol.handlers["/api/v3/movie/55"] = (200, Data("""
        {"id":55,"tmdbId":603,"title":"The Matrix","year":1999,"overview":"x"}
        """.utf8))
        // Radarr's native credit endpoint — no TMDB key involved.
        LocalStubProtocol.handlers["/api/v3/credit"] = (200, Data("""
        [{"personName":"Keanu Reeves","character":"Neo","order":0,"type":"cast"},
         {"personName":"Lana Wachowski","department":"Directing","job":"Director","type":"crew"}]
        """.utf8))

        // backend() has NO tmdbApiKey — movie cast must still work.
        let output = try await backend().callTool(
            name: "get_title_details",
            arguments: .object(["service": .string("radarr"), "id": .number(55), "include_cast": .bool(true)])
        )
        #expect(output.text.contains("Keanu Reeves — Neo"))
        // Crew is excluded from the cast list.
        #expect(!output.text.contains("Lana Wachowski"))
    }

    @Test("get_title_details series cast needs a TMDB key (Sonarr has no cast API)")
    func titleDetailsSeriesCastNoKey() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        LocalStubProtocol.handlers["/api/v3/series/9"] = (200, Data("""
        {"id":9,"tmdbId":1399,"title":"Game of Thrones","year":2011,"overview":"x"}
        """.utf8))

        // No tmdbApiKey configured.
        let output = try await backend().callTool(
            name: "get_title_details",
            arguments: .object(["service": .string("sonarr"), "id": .number(9), "include_cast": .bool(true)])
        )
        #expect(output.text.contains("Cast: unavailable"))
        #expect(output.text.contains("TMDB key"))
    }

    @Test("get_title_details without id prompts for one")
    func titleDetailsMissingId() async throws {
        let output = try await backend().callTool(
            name: "get_title_details",
            arguments: .object(["service": .string("radarr")])
        )
        #expect(output.text.contains("seriesId") || output.text.contains("movieId"))
    }

    // MARK: - Health

    @Test("health with nothing configured reports no services")
    func healthNothingConfigured() async throws {
        let b = LocalToolBackend(sonarr: .empty, radarr: .empty, lidarr: .empty)
        let output = try await b.callTool(name: "health", arguments: .object([:]))
        #expect(output.text == "No services are configured.")
    }

    // MARK: - Custom formats

    @Test("custom_formats with no service arg prompts for one")
    func customFormatsMissingService() async throws {
        let output = try await backend().callTool(name: "custom_formats", arguments: .object([:]))
        #expect(output.text.contains("sonarr"))
        #expect(output.text.contains("radarr"))
    }

    @Test("custom_formats when service not configured returns informative string")
    func customFormatsNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: .empty, radarr: radarrConfig())
        let output = try await b.callTool(
            name: "custom_formats",
            arguments: .object(["service": .string("sonarr")])
        )
        #expect(output.text == "Sonarr is not configured.")
    }

    @Test("custom_formats (no name) stubs HTTP and lists id + name + condition count")
    func customFormatsListed() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        let json = """
        [
          {"id":7,"name":"x265 (HD)","specifications":[
             {"name":"x265","implementation":"ReleaseTitleSpecification","negate":false,"required":false,
              "fields":[{"name":"value","value":"(x|h)\\\\.?265"}]}]},
          {"id":3,"name":"LQ","specifications":[]}
        ]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/customformat"] = (200, json)

        let output = try await backend().callTool(
            name: "custom_formats",
            arguments: .object(["service": .string("radarr")])
        )
        #expect(output.text.contains("x265 (HD)"))
        #expect(output.text.contains("[7]"))
        #expect(output.text.contains("LQ"))
        #expect(output.text.contains("1 condition"))
    }

    @Test("describe_format stubs HTTP and reports conditions + per-profile scores")
    func describeFormatScores() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        let formats = """
        [{"id":7,"name":"x265 (HD)","specifications":[
            {"name":"x265","implementation":"ReleaseTitleSpecification","implementationName":"Release Title",
             "negate":false,"required":false,"fields":[{"name":"value","value":"(x|h)\\\\.?265"}]}]}]
        """.data(using: .utf8)!
        let profiles = """
        [
          {"id":1,"name":"HD-1080p","formatItems":[{"format":7,"name":"x265 (HD)","score":-10000}]},
          {"id":2,"name":"Any","formatItems":[{"format":7,"name":"x265 (HD)","score":0}]}
        ]
        """.data(using: .utf8)!
        LocalStubProtocol.handlers["/api/v3/customformat"] = (200, formats)
        LocalStubProtocol.handlers["/api/v3/qualityprofile"] = (200, profiles)

        let output = try await backend().callTool(
            name: "custom_formats",
            arguments: .object(["service": .string("radarr"), "name": .string("x265")])
        )
        #expect(output.text.contains("x265 (HD)"))
        #expect(output.text.contains("Release Title"))
        #expect(output.text.contains("(x|h)"))         // the matched regex value
        #expect(output.text.contains("HD-1080p"))
        #expect(output.text.contains("-10000"))
        // Any profile scores 0 → excluded from the explicit list, rolled into the "(N other)" tail
        #expect(!output.text.contains("Any: 0"))
    }

    @Test("describe_format reports a helpful miss when the name isn't found")
    func describeFormatNotFound() async throws {
        URLProtocol.registerClass(LocalStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(LocalStubProtocol.self)
            LocalStubProtocol.reset()
        }
        LocalStubProtocol.handlers["/api/v3/customformat"] = (200, Data("""
        [{"id":7,"name":"x265 (HD)","specifications":[]}]
        """.utf8))

        let output = try await backend().callTool(
            name: "custom_formats",
            arguments: .object(["service": .string("radarr"), "name": .string("Bluray Tier 99")])
        )
        #expect(output.text.contains("No custom format"))
        #expect(output.text.contains("x265 (HD)"))   // lists what IS available
    }

    // MARK: - Download queue

    @Test("list_download_queue not configured returns informative string")
    func listQueueNotConfigured() async throws {
        let b = LocalToolBackend(sonarr: .empty, radarr: .empty, lidarr: .empty, whisparr: .empty)
        let output = try await b.callTool(name: "list_download_queue", arguments: .object([:]))
        #expect(output.text == "No arr is configured.")
        #expect(output.rich == nil)
    }

    @Test("The queue tool is offered by a music-only setup, and covers Lidarr")
    func listQueueSpansEveryArr() {
        // The regression this guards: the tool asked Sonarr + Radarr only, so a
        // Lidarr download was absent from an answer that read as the whole
        // queue — and a Lidarr-only user was never offered the tool at all.
        let names = ChatToolCatalog.tools(
            includeSonarr: false, includeRadarr: false, includeLidarr: true
        ).map(\.name)
        #expect(names.contains("list_download_queue"))
    }

    @Test("A hidden Whisparr stays out of the queue listing")
    func listQueueRespectsWhisparrGate() async throws {
        // `aiKnowsAboutWhisparr` is off, so its queue must not ride in on a
        // tool that spans every arr — an arr the user hid from the model must
        // stay hidden.
        let configured = ServiceConfig(enabled: true, baseURL: "http://whisparr.test",
                                       apiKey: "k", username: "", password: "")
        let b = LocalToolBackend(sonarr: .empty, radarr: .empty, lidarr: .empty,
                                 whisparr: configured, aiKnowsAboutWhisparr: false)
        let output = try await b.callTool(name: "list_download_queue", arguments: .object([:]))
        #expect(output.text == "No arr is configured.")
    }

    @Test("An upgrade with no existing-file fields doesn't count as carrying one")
    func existingFileMetadataNeedsFields() {
        #expect(upgradeItem().hasExistingFileMetadata)
        #expect(!plainItem().hasExistingFileMetadata)
        // The case the detail panel turns on: an arr that flags the upgrade but
        // ships none of the `existing*` fields. `isUpgrade` alone would have the
        // panel hide its standalone "Existing file" block in favour of a diff
        // sub-line that then renders nothing.
        let flaggedButEmpty = QueueItem(
            id: "radarr-3", source: .radarr, arrQueueId: 3,
            downloadId: nil, downloadProtocol: .torrent, downloadClient: "qbit",
            title: "Léon", subtitle: nil, status: .downloading,
            progress: 0.2, sizeTotal: 10, sizeLeft: 8, timeLeft: nil,
            customFormats: [], customFormatScore: 0, quality: "2160p", isUpgrade: true,
            contentSlug: nil
        )
        #expect(!flaggedButEmpty.hasExistingFileMetadata)
    }

    private func upgradeItem() -> QueueItem {
        QueueItem(
            id: "sonarr-1", source: .sonarr, arrQueueId: 1,
            downloadId: nil, downloadProtocol: .usenet, downloadClient: "SAB",
            title: "The Wire", subtitle: "S01E01",
            releaseName: "The.Wire.S01E01.2160p.Remux", status: .downloading,
            progress: 0.5, sizeTotal: 24_300_000_000, sizeLeft: 12_000_000_000, timeLeft: "1h",
            customFormats: ["DV", "HDR10", "Remux"], customFormatScore: 120,
            quality: "2160p Remux", isUpgrade: true,
            existingCustomFormats: ["HDR10"], existingCustomFormatScore: 50, existingQuality: "1080p Bluray",
            existingSize: 8_100_000_000, existingFileName: "old.mkv",
            contentSlug: nil
        )
    }

    private func plainItem() -> QueueItem {
        QueueItem(
            id: "radarr-2", source: .radarr, arrQueueId: 2,
            downloadId: nil, downloadProtocol: .torrent, downloadClient: "qbit",
            title: "Dune", subtitle: nil, status: .queued,
            progress: 0.0, sizeTotal: 10_000_000_000, sizeLeft: 10_000_000_000, timeLeft: nil,
            customFormats: [], customFormatScore: 0, quality: "2160p", isUpgrade: false,
            contentSlug: nil
        )
    }

    @Test("formatQueueCondensed emits an UPGRADE diff fragment for upgrade rows")
    func queueUpgradeDiff() {
        let text = LocalToolBackend.formatQueueCondensed([upgradeItem()])
        #expect(text.contains("The Wire"))
        #expect(text.contains("UPGRADE:"))
        #expect(text.contains("1080p Bluray → 2160p Remux"))
        #expect(text.contains("score 50→120"))
        #expect(text.contains("+DV"))      // gained
        #expect(text.contains("+Remux"))   // gained
        #expect(!text.contains("-HDR10"))  // kept on both sides — not lost
    }

    @Test("formatQueueCondensed omits diff for plain (non-upgrade) rows")
    func queuePlainNoDiff() {
        let text = LocalToolBackend.formatQueueCondensed([plainItem()])
        #expect(text.contains("Dune"))
        #expect(!text.contains("UPGRADE:"))
    }

    @Test("formatQueueCondensed reports empty queue")
    func queueEmpty() {
        let text = LocalToolBackend.formatQueueCondensed([])
        #expect(text == "Nothing is downloading right now.")
    }

    @Test("formatQueueCondensed appends unreachable-service warnings")
    func queueWithFailures() {
        let text = LocalToolBackend.formatQueueCondensed([plainItem()], failures: ["Radarr queue unreachable — timeout"])
        #expect(text.contains("Dune"))
        #expect(text.contains("⚠️ Radarr queue unreachable"))
    }
}
