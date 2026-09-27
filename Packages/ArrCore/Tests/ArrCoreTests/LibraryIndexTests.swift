import Testing
import Foundation
@testable import ArrCore

/// Counts `/movie` hits so "did it refetch?" is an assertion rather than a
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

private let libraryIndexState = LibraryIndexStubState()

private let libraryIndexTransport = ScriptedTransport { request in
    let url = request.url
    if url.path.contains("/movie") { libraryIndexState.countMovie(port: url.port) }
    let delay = libraryIndexState.delay
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    if libraryIndexState.failing { return .init(status: 500, "boom") }
    // `tmdbId` is the port: it makes a record traceable to the server it
    // came from, which is the whole point of the changed-config test.
    return .init(#"[{"id":1,"tmdbId":\#(url.port ?? 0),"title":"The Matrix","hasFile":true}]"#)
}

@Suite("LibraryIndex", .serialized, .gateway(libraryIndexTransport))
struct LibraryIndexTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://libraryindex.test:\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A fresh commit bumps the source's version; a cache hit does not")
    func versionBumpsOnCommit() async throws {
        libraryIndexState.reset()

        let index = LibraryIndex()
        let cfg = config(port: 17101)
        #expect(await index.version(for: .radarr) == 0)

        let first = await index.movies(config: cfg)
        #expect(first.count == 1)
        #expect(await index.version(for: .radarr) == 1)

        // Second read is served from the slot — no request, no bump.
        _ = await index.movies(config: cfg)
        #expect(await index.version(for: .radarr) == 1)
        #expect(libraryIndexState.movieHits == 1)
    }

    @Test("Invalidate bumps the version and forces the next read to refetch")
    func invalidateBumpsAndRefetches() async throws {
        libraryIndexState.reset()

        let index = LibraryIndex()
        let cfg = config(port: 17102)
        _ = await index.movies(config: cfg)
        await index.invalidate(.radarr)
        #expect(await index.version(for: .radarr) == 2)

        _ = await index.movies(config: cfg)
        #expect(libraryIndexState.movieHits == 2)
        #expect(await index.version(for: .radarr) == 3)
    }

    @Test("A failed refetch keeps the stale snapshot and does not bump")
    func failedRefetchKeepsStale() async throws {
        libraryIndexState.reset()

        let index = LibraryIndex()
        let cfg = config(port: 17103)
        _ = await index.movies(config: cfg)
        let afterFirst = await index.version(for: .radarr)

        await index.invalidate(.radarr)
        let afterInvalidate = await index.version(for: .radarr)
        libraryIndexState.failing = true

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
        libraryIndexState.reset()
        libraryIndexState.delay = 0.2
        defer { libraryIndexState.delay = 0 }

        let index = LibraryIndex()
        let cfg = config(port: 17104)

        // The second caller joins the in-flight fetch. One fetch is one commit:
        // the version must not move without the records moving with it.
        async let first = index.movies(config: cfg)
        async let second = index.movies(config: cfg)
        let (a, b) = await (first, second)

        #expect(a.count == 1)
        #expect(b.count == 1)
        #expect(libraryIndexState.movieHits == 1)
        #expect(await index.version(for: .radarr) == 1)
    }

    @Test("A fetch in flight for another config is not joined")
    func inFlightIsNotJoinedAcrossConfigs() async throws {
        libraryIndexState.reset()
        libraryIndexState.delay = 0.2
        defer { libraryIndexState.delay = 0 }

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
        #expect(libraryIndexState.movieHits(port: 17105) == 1)
        #expect(libraryIndexState.movieHits(port: 17106) == 1)
        #expect(libraryIndexState.movieHits == 2)
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
