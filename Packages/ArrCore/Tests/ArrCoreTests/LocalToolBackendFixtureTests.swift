import Testing
import Foundation
@testable import ArrCore

/// Every catalogue tool runs against the bundled fixtures: the backend is built from the demo profile and every
/// facade resolves the demo gateway through `ServiceGateway.override`, so nothing leaves the process.
@Suite("Tools on fixtures")
struct LocalToolBackendFixtureTests {
    struct Call: CustomTestStringConvertible {
        let name: String
        let arguments: JSONValue
        /// A fixture title the answer must carry, where the tool lists records.
        var expects: String? = nil
        var testDescription: String { name }
    }

    static let calls: [Call] = [
        Call(name: "sonarr_search", arguments: .object(["query": .string("Pioneer One")])),
        Call(name: "sonarr_get_series", arguments: .object([:]), expects: "Caminandes"),
        Call(name: "sonarr_monitor_season", arguments: .object(["seriesId": .number(1), "seasonNumbers": .array([.number(1)])])),
        Call(name: "sonarr_search_episodes", arguments: .object(["episodeIds": .array([.number(1)])])),
        Call(name: "radarr_search", arguments: .object(["query": .string("Big Buck Bunny")]), expects: "Open Movie"),
        Call(name: "radarr_get_movies", arguments: .object([:]), expects: "Open Movie"),
        Call(name: "radarr_search_movie", arguments: .object(["movieId": .number(1)])),
        Call(name: "lidarr_search", arguments: .object(["query": .string("Nine Inch Nails")]), expects: "Nine Inch Nails"),
        Call(name: "lidarr_get_artists", arguments: .object([:]), expects: "Brad Sucks"),
        Call(name: "lidarr_get_artist_albums", arguments: .object(["artistId": .number(1)])),
        Call(name: "lidarr_monitor_album", arguments: .object(["albumId": .number(1)])),
        Call(name: "lidarr_search_album", arguments: .object(["albumId": .number(1)])),
        Call(name: "whisparr_search", arguments: .object(["query": .string("Open Movie")])),
        Call(name: "whisparr_get_movies", arguments: .object([:])),
        Call(name: "tmdb_search_person", arguments: .object(["query": .string("Ton Roosendaal")])),
        Call(name: "tmdb_discover_movies", arguments: .object([:])),
        Call(name: "tmdb_discover_series", arguments: .object([:])),
        Call(name: "suggest_titles", arguments: .object(["kind": .string("movie"), "items": .array([.object(["title": .string("Big Buck Bunny")])])])),
        Call(name: "check_titles", arguments: .object(["titles": .array([.string("Big Buck Bunny")])])),
        Call(name: "discover_in_quiz", arguments: .object(["mood": .string("cozy"), "kind": .string("movie")])),
        Call(name: "get_calendar", arguments: .object([:]), expects: "Open Movie"),
        Call(name: "health", arguments: .object([:])),
        Call(name: "get_title_details", arguments: .object(["service": .string("radarr"), "id": .number(1)])),
        Call(name: "custom_formats", arguments: .object(["service": .string("radarr")])),
        Call(name: "list_download_queue", arguments: .object([:])),
        Call(name: "media_server_watch_history", arguments: .object([:])),
        Call(name: "media_server_now_playing", arguments: .object([:])),
        Call(name: "media_server_scan_library", arguments: .object([:])),
    ]

    @MainActor
    private static func demo() -> (ServiceGateway, LocalToolBackend) {
        let gateway = ServiceGateway.demo(kinds: [.radarr, .sonarr, .lidarr, .whisparr])
        let store = gateway.configStore
        store.mediaServer = MediaServerConfig(enabled: true, kind: .plex, baseURL: "http://plex.demo.invalid", token: "demo")
        store.tmdbApiKey = "demo"
        let backend = LocalToolBackend(sonarr: store.sonarr, radarr: store.radarr, lidarr: store.lidarr, whisparr: store.whisparr,
                                       aiKnowsAboutWhisparr: true, tmdbApiKey: store.tmdbApiKey, mediaServer: store.mediaServer)
        return (gateway, backend)
    }

    @Test("The catalogue is the 28 tools")
    func catalogueIsComplete() {
        let names = Set(ChatToolCatalog.tools(includeSonarr: true, includeRadarr: true, includeLidarr: true,
                                              includeWhisparr: true, includeTMDBMovies: true, includeTMDBSeries: true,
                                              includeMediaServer: true).map(\.name))
        #expect(names == Set(Self.calls.map(\.name)))
        #expect(names.count == 28)
    }

    @Test("Every tool answers from fixtures", arguments: calls)
    func toolAnswers(call: Call) async throws {
        let (gateway, backend) = await Self.demo()
        let approve: ToolConfirmationHandler = { .approved($0.arguments) }
        let output = try await ServiceGateway.$override.withValue(gateway) {
            try await ToolConfirmationContext.$handler.withValue(approve) {
                try await backend.callTool(name: call.name, arguments: call.arguments)
            }
        }
        let text = output.text.lowercased()
        #expect(!text.isEmpty)
        #expect(!text.contains("not configured"), Comment(rawValue: output.text))
        if let expects = call.expects { #expect(output.text.contains(expects), Comment(rawValue: output.text)) }
        await gateway.kit.stop()
    }
}
