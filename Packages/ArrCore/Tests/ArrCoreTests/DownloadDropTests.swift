import Testing
import Foundation
@testable import ArrCore

// MARK: - Fake transport

private final class DropReply: @unchecked Sendable {
    private let lock = NSLock()
    private var _json: String?
    var json: String? {
        get { lock.withLock { _json } }
        set { lock.withLock { _json = newValue } }
    }
}

private let dropReply = DropReply()

private let dropTransport = ScriptedTransport { request in
    guard request.url.host == "dl-drop.test", let json = dropReply.json else { throw URLError(.unknown) }
    return .init(json)
}

private func config(_ url: String = "http://dl-drop.test:8080", user: String = "u", pass: String = "p") -> ServiceConfig {
    ServiceConfig(enabled: true, baseURL: url, apiKey: "key", username: user, password: pass)
}

/// Serialized because every suite below drives the same `dropReply` slot;
/// `.serialized` applies to descendants, so the nested suites inherit it.
@Suite("Download drops", .serialized, .gateway(dropTransport))
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

    /// Minimal `ArrAPIClient` so the shared extension is exercised with the drop transport answering.
    private struct StubArrClient: ArrAPIClient {
        let config: ServiceConfig
        let source: QueueItem.Source = .sonarr
        let serviceName = "Stub"
    }

    @Suite("Arr download clients")
    struct ArrDownloadClientTests {
        private func clients(_ json: String) async throws -> [ArrDownloadClient] {
            dropReply.json = json
            defer { dropReply.json = nil }
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
}
