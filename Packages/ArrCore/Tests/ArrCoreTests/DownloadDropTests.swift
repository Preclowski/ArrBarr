import Testing
import Foundation
@testable import ArrCore

// MARK: - Fake transport

/// Same fake-transport shape as the other client suites — its own class so the
/// single static handler slot can't be clobbered by a sibling suite.
private final class DropMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    // Scoped to this suite's hosts. Answering every request — suites run in
    // parallel — serves other suites their neighbour's fixture, and the victim
    // sees impossible values (zero requests for a call it definitely made).
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "dl-drop.test"
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

private func config(_ url: String = "http://dl-drop.test:8080", user: String = "u", pass: String = "p") -> ServiceConfig {
    ServiceConfig(enabled: true, baseURL: url, apiKey: "key", username: user, password: pass)
}

private let torrentDrop = DownloadDrop(
    content: .file(Data("d8:announce".utf8), filename: "Show.S01E01.torrent"),
    kind: .torrent,
    displayName: "Show.S01E01.torrent"
)

/// A minimal but structurally valid single-file torrent, for the tests that
/// need a derivable info-hash (`torrentDrop` above is deliberately truncated).
private let validTorrentDrop = DownloadDrop(
    content: .file(
        Data("d8:announce13:http://tr/ann4:infod6:lengthi1e4:name1:a12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee".utf8),
        filename: "Show.S01E01.torrent"
    ),
    kind: .torrent,
    displayName: "Show.S01E01.torrent"
)

/// SHA-1 of `validTorrentDrop`'s info dictionary, independently computed.
private let validTorrentInfoHash = "4de9b0e9855b349178fb7a42f37dc0f2fac3018d"

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

        @Test("A form-encoded dn reads as spaces, not plus signs")
        func magnetPlusEncodedName() throws {
            // Trackers write `dn` in form encoding. URLComponents leaves `+`
            // literal (it is a legal sub-delimiter), so the window used to
            // title the drop "The+Matrix+1999".
            let url = URL(string: "magnet:?xt=urn:btih:abc123&dn=The+Matrix+1999")!
            let drop = try #require(DownloadDrop(url: url))
            #expect(drop.displayName == "The Matrix 1999")
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

    /// Minimal `ArrAPIClient` so the shared extension is exercised with the drop stub answering.
    private struct StubArrClient: ArrAPIClient {
        let config: ServiceConfig
        let source: QueueItem.Source = .sonarr
        let serviceName = "Stub"
    }

    @Suite("Arr download clients")
    struct ArrDownloadClientTests {
        private func clients(_ json: String) async throws -> [ArrDownloadClient] {
            DropMockURLProtocol.handler = { request in reply(request, json) }
            URLProtocol.registerClass(DropMockURLProtocol.self)
            defer { URLProtocol.unregisterClass(DropMockURLProtocol.self) }
            let client = StubArrClient(config: config())
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


    @Suite("Torrent info-hash")
    struct TorrentInfoHashTests {
        @Test("The v1 info-hash of a .torrent file is the SHA-1 of its info dictionary")
        func fileInfoHash() {
            #expect(validTorrentDrop.torrentInfoHash == validTorrentInfoHash)
        }

        @Test("Malformed bencode yields no hash rather than a wrong one")
        func malformedFileHasNoHash() {
            #expect(torrentDrop.torrentInfoHash == nil)
        }

        @Test("A hex btih magnet parses, lowercased")
        func magnetHexHash() {
            let drop = DownloadDrop(
                content: .magnet("magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&dn=x"),
                kind: .torrent, displayName: "x"
            )
            #expect(drop.torrentInfoHash == "0123456789abcdef0123456789abcdef01234567")
        }

        @Test("A base32 btih magnet decodes to the same hex")
        func magnetBase32Hash() {
            let drop = DownloadDrop(
                content: .magnet("magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH"),
                kind: .torrent, displayName: "x"
            )
            #expect(drop.torrentInfoHash == "0123456789abcdef0123456789abcdef01234567")
        }

        @Test("A magnet without a btih carries no hash")
        func magnetWithoutHash() {
            let drop = DownloadDrop(
                content: .magnet("magnet:?dn=just-a-name"),
                kind: .torrent, displayName: "x"
            )
            #expect(drop.torrentInfoHash == nil)
        }
    }
}
