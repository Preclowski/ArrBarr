import Testing
import Foundation
import MediaKit
@testable import ArrCore

/// Lidarr and Whisparr ownership used to come from two hand-rolled fetches
/// inside `SearchClient`. They now read the shared `LibraryIndex` through
/// `ArrLibraryMaps` — and the key has to stay byte-identical to the one the
/// lookup rows carry, or every owned artist silently reads as addable.
private let ownershipTransport = ScriptedTransport { request in
    let path = request.url.path
    if path.contains("/artist") {
        return .init(#"[{"id":11,"foreignArtistId":"mbid-radiohead","artistName":"Radiohead","monitored":true,"statistics":{"trackCount":10,"trackFileCount":10}}]"#)
    }
    if path.contains("/movie") {
        return .init(#"[{"id":22,"foreignId":"scene-abc","tmdbId":0,"title":"Scene","hasFile":true}]"#)
    }
    return .init("[]")
}

@Suite("Search ownership maps", .serialized, .gateway(ownershipTransport))
struct SearchClientOwnershipTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://ownership.test:\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("Lidarr ownership is keyed by the same foreign hash the lookup rows carry")
    func lidarrOwnershipKey() async throws {
        let cfg = config(port: 17201)
        let map = await ArrLibraryMaps.lidarrByForeignArtistHash(config: cfg)
        let key = ArrLibraryMaps.foreignHashKey("mbid-radiohead")
        #expect(map[key]?.arrId == 11)
        #expect(map[key]?.isDownloaded == true)

        // The row side computes the very same key.
        let row = SearchResult(artist: 
            ArrArtist.testRecord(foreignArtistId: "mbid-radiohead", artistName: "Radiohead"),
            baseURL: cfg.baseURL)
        #expect(row?.externalId == key)
    }

    @Test("Whisparr ownership prefers tmdbId and falls back to the foreign hash")
    func whisparrOwnershipKey() async throws {
        let cfg = config(port: 17202)
        let map = await ArrLibraryMaps.whisparrByForeignId(config: cfg)
        // tmdbId is 0 on this record, so the foreign hash is the key.
        let key = ArrLibraryMaps.foreignHashKey("scene-abc")
        #expect(map[key]?.arrId == 22)
        #expect(map[key]?.isDownloaded == true)
    }

    @Test("An unconfigured arr yields an empty map rather than a request")
    func unconfiguredIsEmpty() async {
        #expect(await ArrLibraryMaps.lidarrByForeignArtistHash(config: .empty).isEmpty)
        #expect(await ArrLibraryMaps.whisparrByForeignId(config: .empty).isEmpty)
    }
}

private extension ArrArtist {
    /// The decoder is the only initialiser on the wire type, so the test
    /// builds one through it.
    static func testRecord(foreignArtistId: String, artistName: String) -> ArrArtist {
        let json = #"{"foreignArtistId":"\#(foreignArtistId)","artistName":"\#(artistName)"}"#
        return try! JSONDecoder().decode(ArrArtist.self, from: Data(json.utf8))
    }
}
