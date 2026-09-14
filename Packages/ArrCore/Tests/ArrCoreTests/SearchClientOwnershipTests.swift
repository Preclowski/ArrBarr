import Testing
import Foundation
@testable import ArrCore

/// Lidarr and Whisparr ownership used to come from two hand-rolled fetches
/// inside `SearchClient`. They now read the shared `LibraryIndex` through
/// `ArrLibraryMaps` — and the key has to stay byte-identical to the one the
/// lookup rows carry, or every owned artist silently reads as addable.
private final class OwnershipStub: URLProtocol, @unchecked Sendable {
    static let host = "ownership.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        let body: String
        if url.path.contains("/artist") {
            body = #"[{"id":11,"foreignArtistId":"mbid-radiohead","artistName":"Radiohead","monitored":true,"statistics":{"trackCount":10,"trackFileCount":10}}]"#
        } else if url.path.contains("/movie") {
            body = #"[{"id":22,"foreignId":"scene-abc","tmdbId":0,"title":"Scene","hasFile":true}]"#
        } else {
            body = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Search ownership maps", .serialized)
struct SearchClientOwnershipTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(OwnershipStub.host):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("Lidarr ownership is keyed by the same foreign hash the lookup rows carry")
    func lidarrOwnershipKey() async throws {
        URLProtocol.registerClass(OwnershipStub.self)
        defer { URLProtocol.unregisterClass(OwnershipStub.self) }

        let cfg = config(port: 17201)
        let map = await ArrLibraryMaps.lidarrByForeignArtistHash(config: cfg)
        let key = ArrLibraryMaps.foreignHashKey("mbid-radiohead")
        #expect(map[key]?.arrId == 11)
        #expect(map[key]?.isDownloaded == true)

        // The row side computes the very same key.
        let row = SearchClient.unifyLidarr(
            LidarrLookupRecord.testRecord(foreignArtistId: "mbid-radiohead", artistName: "Radiohead"),
            baseURL: cfg.baseURL)
        #expect(row?.externalId == key)
    }

    @Test("Whisparr ownership prefers tmdbId and falls back to the foreign hash")
    func whisparrOwnershipKey() async throws {
        URLProtocol.registerClass(OwnershipStub.self)
        defer { URLProtocol.unregisterClass(OwnershipStub.self) }

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

private extension LidarrLookupRecord {
    /// The decoder is the only initialiser on the wire type, so the test
    /// builds one through it.
    static func testRecord(foreignArtistId: String, artistName: String) -> LidarrLookupRecord {
        let json = #"{"foreignArtistId":"\#(foreignArtistId)","artistName":"\#(artistName)"}"#
        return try! JSONDecoder().decode(LidarrLookupRecord.self, from: Data(json.utf8))
    }
}
