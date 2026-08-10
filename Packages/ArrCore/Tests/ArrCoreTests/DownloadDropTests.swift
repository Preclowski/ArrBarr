import Testing
import Foundation
@testable import ArrCore

// MARK: - Fake transport

/// Same fake-transport shape as the other client suites — its own class so the
/// single static handler slot can't be clobbered by a sibling suite.
private final class DropMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
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

private func dropSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DropMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func reply(_ request: URLRequest, _ text: String, statusCode: Int = 200) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    return (Data(text.utf8), response)
}

/// URLSession moves a request's `httpBody` into `httpBodyStream` by the time a
/// `URLProtocol` sees it, so every body assertion in this file has to drain the
/// stream rather than read `httpBody` (which is always nil here).
private func body(of request: URLRequest) -> String {
    guard let stream = request.httpBodyStream else {
        return request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let size = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: size)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func config(_ url: String = "http://localhost:8080", user: String = "u", pass: String = "p") -> ServiceConfig {
    ServiceConfig(enabled: true, baseURL: url, apiKey: "key", username: user, password: pass)
}

private let torrentDrop = DownloadDrop(
    content: .file(Data("d8:announce".utf8), filename: "Show.S01E01.torrent"),
    kind: .torrent,
    displayName: "Show.S01E01.torrent"
)

private let nzbDrop = DownloadDrop(
    content: .file(Data("<nzb/>".utf8), filename: "Show.S01E01.nzb"),
    kind: .usenet,
    displayName: "Show.S01E01.nzb"
)

/// One serialized outer suite on purpose: every suite below drives the SAME
/// `DropMockURLProtocol.handler` slot, and swift-testing runs suites in
/// parallel by default — so without this they hand each other's fixtures out
/// and fail in whichever order they happen to interleave. `.serialized`
/// applies to descendants, so the nested suites inherit it.
@Suite("Download drops", .serialized)
struct DownloadDropSuite {
    // MARK: - Payload parsing

    @Suite("Download drop parsing")
    struct DownloadDropParsingTests {
        @Test("A magnet link takes its display name from dn")
        func magnetDisplayName() throws {
            let url = URL(string: "magnet:?xt=urn:btih:abc123&dn=Severance.S02E07.2160p")!
            let drop = try #require(DownloadDrop(url: url))
            #expect(drop.kind == .torrent)
            #expect(drop.displayName == "Severance.S02E07.2160p")
            #expect(drop.content == .magnet(url.absoluteString))
        }

        @Test("A magnet without dn falls back to the link itself rather than an empty row")
        func magnetWithoutName() throws {
            let url = URL(string: "magnet:?xt=urn:btih:abc123")!
            let drop = try #require(DownloadDrop(url: url))
            #expect(drop.displayName == url.absoluteString)
        }

        @Test("Extensions decide the protocol, and anything else is ignored")
        func fileKinds() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            let torrent = dir.appendingPathComponent("\(UUID()).torrent")
            let nzb = dir.appendingPathComponent("\(UUID()).nzb")
            let other = dir.appendingPathComponent("\(UUID()).txt")
            for url in [torrent, nzb, other] { try Data("payload".utf8).write(to: url) }
            defer { for url in [torrent, nzb, other] { try? FileManager.default.removeItem(at: url) } }

            #expect(DownloadDrop(url: torrent)?.kind == .torrent)
            #expect(DownloadDrop(url: nzb)?.kind == .usenet)
            // A stray file in the same drag must not become a download.
            #expect(DownloadDrop(url: other) == nil)
        }

        @Test("An empty file is refused — an empty .torrent would only fail at the client")
        func emptyFileRejected() throws {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).torrent")
            try Data().write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(DownloadDrop(url: url) == nil)
        }

        @Test("Arr implementations map onto the clients we can actually reach")
        func implementationMapping() {
            func client(_ implementation: String) -> ArrDownloadClient {
                ArrDownloadClient(id: 1, name: "c", implementation: implementation, kind: .torrent, category: nil)
            }
            #expect(client("QBittorrent").serviceKind == .qbittorrent)
            #expect(client("qbittorrent").serviceKind == .qbittorrent)
            #expect(client("Sabnzbd").serviceKind == .sabnzbd)
            #expect(client("RTorrent").serviceKind == .rtorrent)
            // Clients ArrBarr has no support for must resolve to nil so the sheet
            // filters them out instead of offering a destination that can't work.
            #expect(client("Flood").serviceKind == nil)
        }
    }

    // MARK: - Arr download-client resolution

    /// Minimal `ArrAPIClient` whose transport we control — `SonarrClient` and
    /// friends build their own `HTTPClient`, so the shared extension is exercised
    /// through this instead.
    private struct StubArrClient: ArrAPIClient {
        let config: ServiceConfig
        let apiBase = "/api/v3"
        let serviceName = "Stub"
        let http: HTTPClient
    }

    @Suite("Arr download clients")
    struct ArrDownloadClientTests {
        private func clients(_ json: String) async throws -> [ArrDownloadClient] {
            DropMockURLProtocol.handler = { request in reply(request, json) }
            let client = StubArrClient(config: config(), http: HTTPClient(session: dropSession()))
            return try await client.fetchDownloadClients()
        }

        @Test("The category comes from the media-type field, never the imported one")
        func categoryFromMediaField() async throws {
            let result = try await clients("""
            [{"id":1,"name":"qBit","implementation":"QBittorrent","enable":true,"protocol":"torrent",
              "fields":[{"name":"tvImportedCategory","value":"tv-sonarr-imported"},
                        {"name":"tvCategory","value":"tv-sonarr"}]}]
            """)
            // Putting a fresh download in the *imported* category means the arr
            // never picks it up — the distinction is the whole feature.
            #expect(result.count == 1)
            #expect(result[0].category == "tv-sonarr")
        }

        @Test("Disabled clients are dropped — the arr isn't watching them")
        func disabledDropped() async throws {
            let result = try await clients("""
            [{"id":1,"name":"off","implementation":"QBittorrent","enable":false,"protocol":"torrent","fields":[]},
             {"id":2,"name":"on","implementation":"Sabnzbd","enable":true,"protocol":"usenet","fields":[]}]
            """)
            #expect(result.map(\.id) == [2])
            #expect(result[0].kind == .usenet)
        }

        @Test("A non-string field value doesn't cost us the whole client")
        func mixedFieldTypesSurvive() async throws {
            // `fields` is polymorphic across implementations; a strict decode would
            // throw on the int and lose the client — and with it the arr.
            let result = try await clients("""
            [{"id":3,"name":"qBit","implementation":"QBittorrent","enable":true,"protocol":"torrent",
              "fields":[{"name":"port","value":8080},{"name":"movieCategory","value":"radarr"}]}]
            """)
            #expect(result.count == 1)
            #expect(result[0].category == "radarr")
        }

        @Test("Lidarr's enum-name protocol parses the same as Sonarr's wire value")
        func lidarrProtocolSpelling() async throws {
            // Lidarr (API v1) serialises the enum's *name*; the v3 arrs send
            // its value. An exact match dropped every Lidarr client, so Lidarr
            // never appeared as a destination at all.
            let result = try await clients("""
            [{"id":1,"name":"qBit","implementation":"QBittorrent","enable":true,"protocol":"TorrentDownloadProtocol",
              "fields":[{"name":"musicCategory","value":"lidarr"}]},
             {"id":2,"name":"SAB","implementation":"Sabnzbd","enable":true,"protocol":"UsenetDownloadProtocol","fields":[]}]
            """)
            #expect(result.map(\.kind) == [.torrent, .usenet])
            #expect(result[0].category == "lidarr")
        }

        @Test("A protocol we've never seen is still refused")
        func unknownProtocolDropped() async throws {
            let result = try await clients("""
            [{"id":1,"name":"x","implementation":"QBittorrent","enable":true,"protocol":"carrierPigeon","fields":[]}]
            """)
            #expect(result.isEmpty)
        }

        @Test("An empty category reads as none rather than an empty string")
        func blankCategory() async throws {
            let result = try await clients("""
            [{"id":4,"name":"qBit","implementation":"QBittorrent","enable":true,"protocol":"torrent",
              "fields":[{"name":"tvCategory","value":""}]}]
            """)
            #expect(result[0].category == nil)
        }
    }

    // MARK: - Adding to clients

    @Suite("qBittorrent add")
    struct QbittorrentAddTests {
        @Test("A torrent file goes up as multipart with the arr's category")
        func addsFileWithCategory() async throws {
            nonisolated(unsafe) var seen = ""
            DropMockURLProtocol.handler = { request in
                if request.url?.path.contains("auth/login") == true { return reply(request, "Ok.") }
                seen = body(of: request)
                return reply(request, "Ok.")
            }
            let client = QbittorrentClient(config: config(), session: dropSession())
            try await client.add(torrentDrop, category: "tv-sonarr", paused: false)

            #expect(seen.contains("name=\"category\""))
            #expect(seen.contains("tv-sonarr"))
            #expect(seen.contains("name=\"torrents\"; filename=\"Show.S01E01.torrent\""))
            #expect(seen.contains("d8:announce"))
        }

        @Test("Paused is sent under both the 4.x and 5.x spellings")
        func pausedBothSpellings() async throws {
            nonisolated(unsafe) var seen = ""
            DropMockURLProtocol.handler = { request in
                if request.url?.path.contains("auth/login") == true { return reply(request, "Ok.") }
                seen = body(of: request)
                return reply(request, "Ok.")
            }
            let client = QbittorrentClient(config: config(), session: dropSession())
            try await client.add(torrentDrop, category: nil, paused: true)

            #expect(seen.contains("name=\"paused\""))
            #expect(seen.contains("name=\"stopped\""))
            #expect(!seen.contains("false"))
        }

        @Test("A magnet travels as a urls field, with no file part")
        func addsMagnet() async throws {
            nonisolated(unsafe) var seen = ""
            DropMockURLProtocol.handler = { request in
                if request.url?.path.contains("auth/login") == true { return reply(request, "Ok.") }
                seen = body(of: request)
                return reply(request, "Ok.")
            }
            let drop = DownloadDrop(content: .magnet("magnet:?xt=urn:btih:abc"), kind: .torrent, displayName: "abc")
            let client = QbittorrentClient(config: config(), session: dropSession())
            try await client.add(drop, category: nil, paused: false)

            #expect(seen.contains("name=\"urls\""))
            #expect(seen.contains("magnet:?xt=urn:btih:abc"))
            #expect(!seen.contains("filename="))
        }

        @Test("\"Fails.\" is a failure even though it arrives as HTTP 200")
        func rejectionSurfaces() async throws {
            DropMockURLProtocol.handler = { request in
                if request.url?.path.contains("auth/login") == true { return reply(request, "Ok.") }
                return reply(request, "Fails.")
            }
            let client = QbittorrentClient(config: config(), session: dropSession())
            await #expect(throws: QbittorrentError.self) {
                try await client.add(torrentDrop, category: nil, paused: false)
            }
        }
    }

    @Suite("Transmission add")
    struct TransmissionAddTests {
        @Test("The category becomes a subdirectory of the client's download dir")
        func categoryBecomesDirectory() async throws {
            nonisolated(unsafe) var lastAdd: [String: Any] = [:]
            DropMockURLProtocol.handler = { request in
                let text = body(of: request)
                if text.contains("session-get") {
                    return reply(request, #"{"result":"success","arguments":{"download-dir":"/downloads"}}"#)
                }
                if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   let args = json["arguments"] as? [String: Any] {
                    lastAdd = args
                }
                return reply(request, #"{"result":"success"}"#)
            }
            let client = TransmissionClient(config: config(), session: dropSession())
            try await client.add(torrentDrop, category: "tv-sonarr", paused: true)

            // Transmission has no labels the arrs read; the path IS the category.
            #expect(lastAdd["download-dir"] as? String == "/downloads/tv-sonarr")
            #expect(lastAdd["paused"] as? Bool == true)
            #expect((lastAdd["metainfo"] as? String) == Data("d8:announce".utf8).base64EncodedString())
        }

        @Test("start-added-torrents inverts into the paused default")
        func pausedDefaultInverted() async throws {
            DropMockURLProtocol.handler = { request in
                reply(request, #"{"result":"success","arguments":{"start-added-torrents":false}}"#)
            }
            let client = TransmissionClient(config: config(), session: dropSession())
            #expect(await client.defaultAddPaused() == true)
        }
    }

    @Suite("SABnzbd add")
    struct SabnzbdAddTests {
        @Test("An nzb goes up as multipart under the arr's category")
        func addsNzb() async throws {
            nonisolated(unsafe) var seen = ""
            nonisolated(unsafe) var mode = ""
            DropMockURLProtocol.handler = { request in
                seen = body(of: request)
                mode = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "mode" }?.value ?? ""
                return reply(request, #"{"status":true}"#)
            }
            let client = SabnzbdClient(config: config(), session: dropSession())
            try await client.add(nzbDrop, category: "tv-sonarr", paused: false)

            #expect(mode == "addfile")
            #expect(seen.contains("name=\"nzbfile\"; filename=\"Show.S01E01.nzb\""))
            #expect(seen.contains("name=\"cat\""))
            // Not paused → SAB's paused priority must be absent entirely.
            #expect(!seen.contains("priority"))
        }

        @Test("Paused is SAB's -2 priority, since it has no per-job pause flag")
        func pausedPriority() async throws {
            nonisolated(unsafe) var seen = ""
            DropMockURLProtocol.handler = { request in
                seen = body(of: request)
                return reply(request, #"{"status":true}"#)
            }
            let client = SabnzbdClient(config: config(), session: dropSession())
            try await client.add(nzbDrop, category: nil, paused: true)

            #expect(seen.contains("name=\"priority\""))
            #expect(seen.contains("-2"))
        }

        @Test("A magnet can never reach a usenet client")
        func magnetRefused() async throws {
            DropMockURLProtocol.handler = { request in reply(request, #"{"status":true}"#) }
            let drop = DownloadDrop(content: .magnet("magnet:?xt=urn:btih:abc"), kind: .torrent, displayName: "abc")
            let client = SabnzbdClient(config: config(), session: dropSession())
            await #expect(throws: SabnzbdError.self) {
                try await client.add(drop, category: nil, paused: false)
            }
        }
    }

    @Suite("NZBGet add")
    struct NzbgetAddTests {
        @Test("append carries the file base64'd, with category and paused in their slots")
        func appendParameters() async throws {
            nonisolated(unsafe) var params: [Any] = []
            DropMockURLProtocol.handler = { request in
                let text = body(of: request)
                if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   json["method"] as? String == "append" {
                    params = json["params"] as? [Any] ?? []
                }
                return reply(request, #"{"result":7}"#)
            }
            let client = NzbgetClient(config: config(), session: dropSession())
            try await client.add(nzbDrop, category: "tv-sonarr", paused: true)

            #expect(params.count == 10)
            #expect(params[0] as? String == "Show.S01E01.nzb")
            #expect(params[1] as? String == Data("<nzb/>".utf8).base64EncodedString())
            #expect(params[2] as? String == "tv-sonarr")
            #expect(params[5] as? Bool == true)
        }

        @Test("A zero id is a refusal, not a success")
        func zeroIdIsFailure() async throws {
            DropMockURLProtocol.handler = { request in reply(request, #"{"result":0}"#) }
            let client = NzbgetClient(config: config(), session: dropSession())
            await #expect(throws: NzbgetError.self) {
                try await client.add(nzbDrop, category: nil, paused: false)
            }
        }
    }

    @Suite("rTorrent add")
    struct RtorrentAddTests {
        @Test("The label rides along as a load-time command, base64 for the payload")
        func loadWithLabel() async throws {
            nonisolated(unsafe) var seen = ""
            DropMockURLProtocol.handler = { request in
                seen = body(of: request)
                return reply(request, "<methodResponse><params><param><value><i4>0</i4></value></param></params></methodResponse>")
            }
            let client = RtorrentClient(config: config(), session: dropSession())
            try await client.add(torrentDrop, category: "tv-sonarr", paused: false)

            #expect(seen.contains("<methodName>load.raw_start</methodName>"))
            #expect(seen.contains("<base64>\(Data("d8:announce".utf8).base64EncodedString())</base64>"))
            // d.custom1 is the field every arr reads back as the label, and it can
            // only be set while loading.
            #expect(seen.contains("d.custom1.set=tv-sonarr"))
        }

        @Test("Paused picks the non-starting load method")
        func pausedUsesLoadRaw() async throws {
            nonisolated(unsafe) var seen = ""
            DropMockURLProtocol.handler = { request in
                seen = body(of: request)
                return reply(request, "<methodResponse></methodResponse>")
            }
            let client = RtorrentClient(config: config(), session: dropSession())
            try await client.add(torrentDrop, category: nil, paused: true)

            #expect(seen.contains("<methodName>load.raw</methodName>"))
            #expect(!seen.contains("load.raw_start"))
        }

        @Test("An XML-RPC fault surfaces instead of reading as success")
        func faultSurfaces() async throws {
            DropMockURLProtocol.handler = { request in
                reply(request, "<methodResponse><fault><value><struct><member><name>faultString</name><value><string>Could not open file</string></value></member></struct></value></fault></methodResponse>")
            }
            let client = RtorrentClient(config: config(), session: dropSession())
            await #expect(throws: RtorrentError.self) {
                try await client.add(torrentDrop, category: nil, paused: false)
            }
        }
    }

}
