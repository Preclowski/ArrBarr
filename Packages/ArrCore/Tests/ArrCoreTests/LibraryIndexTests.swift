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
    private var _movieHitsByPort: [Int: Int] = [:]
    private var _failing = false
    private var _delay: TimeInterval = 0

    var movieHits: Int { lock.lock(); defer { lock.unlock() }; return _movieHits }
    /// Per-port hits: two configs pointing at different servers are two
    /// different libraries, and "did each one get its own fetch?" can only be
    /// asked port by port.
    func movieHits(port: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _movieHitsByPort[port] ?? 0
    }
    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); defer { lock.unlock() }; _failing = newValue }
    }
    /// Held before responding so a second caller really does arrive while the
    /// first fetch is still in flight — without it the race never happens.
    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); defer { lock.unlock() }; _delay = newValue }
    }
    func countMovie(port: Int?) {
        lock.lock(); defer { lock.unlock() }
        _movieHits += 1
        if let port { _movieHitsByPort[port, default: 0] += 1 }
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _movieHits = 0; _movieHitsByPort = [:]; _failing = false; _delay = 0
    }
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
        if url.path.contains("/movie") { Self.state.countMovie(port: url.port) }
        // `startLoading` runs off the main thread, so blocking here is fine.
        let delay = Self.state.delay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if Self.state.failing {
            let response = HTTPURLResponse(url: url, statusCode: 500,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("boom".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // `tmdbId` is the port: it makes a record traceable to the server it
        // came from, which is the whole point of the changed-config test.
        let body = Data(#"[{"id":1,"tmdbId":\#(url.port ?? 0),"title":"The Matrix","hasFile":true}]"#.utf8)
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

    @Test("Two concurrent cold reads are one fetch and one version bump")
    func concurrentColdReadsCommitOnce() async throws {
        LibraryIndexStub.state.reset()
        LibraryIndexStub.state.delay = 0.2
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer {
            URLProtocol.unregisterClass(LibraryIndexStub.self)
            LibraryIndexStub.state.delay = 0
        }

        let index = LibraryIndex()
        let cfg = config(port: 17104)

        // The second caller joins the in-flight fetch. One fetch is one commit:
        // the version must not move without the records moving with it.
        async let first = index.movies(config: cfg)
        async let second = index.movies(config: cfg)
        let (a, b) = await (first, second)

        #expect(a.count == 1)
        #expect(b.count == 1)
        #expect(LibraryIndexStub.state.movieHits == 1)
        #expect(await index.version(for: .radarr) == 1)
    }

    @Test("A fetch in flight for another config is not joined")
    func inFlightIsNotJoinedAcrossConfigs() async throws {
        LibraryIndexStub.state.reset()
        LibraryIndexStub.state.delay = 0.2
        URLProtocol.registerClass(LibraryIndexStub.self)
        defer {
            URLProtocol.unregisterClass(LibraryIndexStub.self)
            LibraryIndexStub.state.delay = 0
        }

        let index = LibraryIndex()
        let a = config(port: 17105)
        let b = config(port: 17106)

        // B arrives while A's cold fetch is still in flight. Joining it would
        // hand B the OTHER server's records — and commit them under B's
        // fingerprint, fresh for a whole ttl.
        async let first = index.movies(config: a)
        async let second: [RadarrLibraryRecord] = {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await index.movies(config: b)
        }()
        let (recordsA, recordsB) = await (first, second)

        #expect(recordsA.first?.tmdbId == 17105)
        #expect(recordsB.first?.tmdbId == 17106)
        #expect(LibraryIndexStub.state.movieHits(port: 17105) == 1)
        #expect(LibraryIndexStub.state.movieHits(port: 17106) == 1)
        #expect(LibraryIndexStub.state.movieHits == 2)
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
