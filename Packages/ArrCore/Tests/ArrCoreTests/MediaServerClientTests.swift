import Testing
import Foundation
@testable import ArrCore

// MARK: - Fake transport

/// Own `URLProtocol` subclass, scoped to its own host — the handler is one
/// static slot per class, and suites run in parallel (see
/// `SabnzbdClientTests` for the full reasoning).
private final class MediaMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "media.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func mediaHTTP() -> HTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MediaMockURLProtocol.self]
    return HTTPClient(session: URLSession(configuration: config))
}

private func reply(_ request: URLRequest, _ text: String) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (Data(text.utf8), response)
}

/// Method + path + sorted query, which is all a maintenance call is.
private func describe(_ request: URLRequest) -> String {
    let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    let query = (comps.queryItems ?? [])
        .sorted { $0.name < $1.name }
        .map { "\($0.name)=\($0.value ?? "")" }
        .joined(separator: "&")
    return "\(request.httpMethod ?? "GET") \(comps.path)" + (query.isEmpty ? "" : "?\(query)")
}

private func config(_ kind: MediaServerKind) -> MediaServerConfig {
    var cfg = MediaServerConfig()
    cfg.enabled = true
    cfg.kind = kind
    cfg.baseURL = "http://media.test"
    cfg.token = "tok"
    cfg.userId = "u1"
    return cfg
}

private let plexSections = """
{"MediaContainer":{"Directory":[
  {"key":"1","title":"Movies","type":"movie"},
  {"key":"2","title":"TV","type":"show"},
  {"key":"3","title":"Music","type":"artist"},
  {"key":"4","title":"Photos","type":"photo"}
]}}
"""

private let jellyfinFolders = """
[
  {"Name":"Movies","ItemId":"f1","CollectionType":"movies"},
  {"Name":"Shows","ItemId":"f2","CollectionType":"tvshows"},
  {"Name":"Mixed","ItemId":"f3"},
  {"Name":"Broken","CollectionType":"music"}
]
"""

// MARK: - Per-library maintenance

@Suite(.serialized)
struct MediaServerLibraryMaintenanceTests {

    @Test
    func plexLibrariesComeFromSections() async throws {
        MediaMockURLProtocol.handler = { reply($0, plexSections) }
        let libs = try await PlexClient(config: config(.plex), http: mediaHTTP()).libraries()
        #expect(libs.map(\.id) == ["1", "2", "3", "4"])
        #expect(libs.map(\.name) == ["Movies", "TV", "Music", "Photos"])
        #expect(libs.map(\.kind) == [.movies, .series, .music, .other])
    }

    @Test
    func plexScanAndTrashTargetOneSection() async throws {
        nonisolated(unsafe) var calls: [String] = []
        MediaMockURLProtocol.handler = { req in
            calls.append(describe(req))
            return reply(req, "{}")
        }
        let client = PlexClient(config: config(.plex), http: mediaHTTP())
        try await client.scanLibrary(id: "2")
        try await client.emptyTrash(libraryId: "2")
        #expect(calls == ["GET /library/sections/2/refresh", "PUT /library/sections/2/emptyTrash"])
    }

    @Test
    func jellyfinLibrariesComeFromVirtualFolders() async throws {
        MediaMockURLProtocol.handler = { reply($0, jellyfinFolders) }
        let libs = try await JellyfinClient(config: config(.jellyfin), http: mediaHTTP()).libraries()
        // The folder without an ItemId can't be addressed, so it's dropped.
        #expect(libs.map(\.id) == ["f1", "f2", "f3"])
        #expect(libs.map(\.kind) == [.movies, .series, .other])
    }

    @Test
    func jellyfinScanIsARecursiveRefreshOfTheFolder() async throws {
        nonisolated(unsafe) var calls: [String] = []
        MediaMockURLProtocol.handler = { req in
            calls.append(describe(req))
            return reply(req, "")
        }
        try await JellyfinClient(config: config(.emby), http: mediaHTTP()).scanLibrary(id: "f2")
        #expect(calls == ["POST /Items/f2/Refresh?ImageRefreshMode=Default&MetadataRefreshMode=Default&Recursive=true"])
    }

    @Test
    func jellyfinHasNoTrash() async {
        MediaMockURLProtocol.handler = { reply($0, "") }
        await #expect(throws: MediaServerError.self) {
            try await JellyfinClient(config: config(.jellyfin), http: mediaHTTP()).emptyTrash(libraryId: "f1")
        }
    }

    /// The whole-server scan the chat tool asks for is the per-library scan
    /// applied to every library the server lists.
    @Test
    func scanAllVisitsEveryLibrary() async throws {
        nonisolated(unsafe) var calls: [String] = []
        MediaMockURLProtocol.handler = { req in
            calls.append(describe(req))
            return reply(req, req.url!.path == "/library/sections" ? plexSections : "{}")
        }
        try await PlexClient(config: config(.plex), http: mediaHTTP()).scanLibraries()
        #expect(calls == [
            "GET /library/sections",
            "GET /library/sections/1/refresh",
            "GET /library/sections/2/refresh",
            "GET /library/sections/3/refresh",
            "GET /library/sections/4/refresh",
        ])
    }
}
