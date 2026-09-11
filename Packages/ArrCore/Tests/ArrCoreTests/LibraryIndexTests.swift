import Testing
import Foundation
@testable import ArrCore

/// Stubs one host so suites running in parallel keep their own traffic, and
/// counts `/movie` hits so "did it refetch?" is an assertion rather than a
/// guess. Each test uses its own port: `LibraryIndex` keys every slot on the
/// config fingerprint, so a distinct base URL is a distinct cache.
private final class LibraryIndexStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _movieHits = 0
    private var _failing = false

    var movieHits: Int { lock.lock(); defer { lock.unlock() }; return _movieHits }
    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); defer { lock.unlock() }; _failing = newValue }
    }
    func countMovie() { lock.lock(); defer { lock.unlock() }; _movieHits += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; _movieHits = 0; _failing = false }
}

private final class LibraryIndexStub: URLProtocol, @unchecked Sendable {
    static let state = LibraryIndexStubState()
    static let host = "libraryindex.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        if url.path.contains("/movie") { Self.state.countMovie() }
        if Self.state.failing {
            let response = HTTPURLResponse(url: url, statusCode: 500,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("boom".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = Data(#"[{"id":1,"tmdbId":603,"title":"The Matrix","hasFile":true}]"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("LibraryIndex", .serialized)
struct LibraryIndexTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(LibraryIndexStub.host):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A fresh commit bumps the source's version; a cache hit does not")
    func versionBumpsOnCommit() async throws {
        LibraryIndexStub.state.reset()
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer { URLProtocol.unregisterClass(LibraryIndexStub.self) }

        let index = LibraryIndex()
        let cfg = config(port: 17101)
        #expect(await index.version(for: .radarr) == 0)

        let first = await index.movies(config: cfg)
        #expect(first.count == 1)
        #expect(await index.version(for: .radarr) == 1)

        // Second read is served from the slot — no request, no bump.
        _ = await index.movies(config: cfg)
        #expect(await index.version(for: .radarr) == 1)
        #expect(LibraryIndexStub.state.movieHits == 1)
    }

    @Test("Invalidate bumps the version and forces the next read to refetch")
    func invalidateBumpsAndRefetches() async throws {
        LibraryIndexStub.state.reset()
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer { URLProtocol.unregisterClass(LibraryIndexStub.self) }

        let index = LibraryIndex()
        let cfg = config(port: 17102)
        _ = await index.movies(config: cfg)
        await index.invalidate(.radarr)
        #expect(await index.version(for: .radarr) == 2)

        _ = await index.movies(config: cfg)
        #expect(LibraryIndexStub.state.movieHits == 2)
        #expect(await index.version(for: .radarr) == 3)
    }

    @Test("A failed refetch keeps the stale snapshot and does not bump")
    func failedRefetchKeepsStale() async throws {
        LibraryIndexStub.state.reset()
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer { URLProtocol.unregisterClass(LibraryIndexStub.self) }

        let index = LibraryIndex()
        let cfg = config(port: 17103)
        _ = await index.movies(config: cfg)
        let afterFirst = await index.version(for: .radarr)

        await index.invalidate(.radarr)
        let afterInvalidate = await index.version(for: .radarr)
        LibraryIndexStub.state.failing = true

        // A momentarily unreachable arr must not read as "your library is
        // empty" — that is "you own nothing" everywhere downstream.
        let stale = await index.movies(config: cfg)
        #expect(stale.count == 1)
        #expect(await index.version(for: .radarr) == afterInvalidate)
        #expect(afterInvalidate == afterFirst + 1)
        #expect(await index.fetchFailed(.radarr))
    }

    @Test("All four sources have a version and all four invalidate")
    func allFourSourcesInvalidate() async {
        let index = LibraryIndex()
        for source in QueueItem.Source.allCases {
            #expect(await index.version(for: source) == 0)
            await index.invalidate(source)
            #expect(await index.version(for: source) == 1)
        }
    }
}
