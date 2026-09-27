import Testing
import Foundation
@testable import ArrCore

/// Counts `/movie` hits so "did it refetch?" is an assertion rather than a guess.
private final class LibraryIndexStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _movieHits = 0
    private var _failing = false

    var movieHits: Int { lock.withLock { _movieHits } }
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    func countMovie() { lock.withLock { _movieHits += 1 } }
    func reset() { lock.withLock { _movieHits = 0; _failing = false } }
}

private let libraryIndexState = LibraryIndexStubState()

private let libraryIndexTransport = ScriptedTransport { request in
    let url = request.url
    if url.path.hasSuffix("/movie") { libraryIndexState.countMovie() }
    if libraryIndexState.failing { return .init(status: 500, "boom") }
    // `tmdbId` is the port, so a record is traceable to the server it came from.
    return .init(#"[{"id":1,"tmdbId":\#(url.port ?? 0),"title":"The Matrix","hasFile":true}]"#)
}

@Suite("LibraryIndex", .serialized, .gateway(libraryIndexTransport))
struct LibraryIndexTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://libraryindex.test:\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A read that reaches the arr moves the source's version")
    func versionMovesOnCommit() async {
        libraryIndexState.reset()
        let cfg = config(port: 17101)
        let before = await LibraryIndex.shared.version(for: .radarr, config: cfg)

        let read = await LibraryIndex.shared.moviesRead(config: cfg)
        #expect(read.records.count == 1)
        #expect(!read.failed)
        let after = await LibraryIndex.shared.version(for: .radarr, config: cfg)
        #expect(after != before)
        #expect(await LibraryIndex.shared.version(for: .radarr, config: cfg) == after)
    }

    @Test("Invalidate moves the version")
    func invalidateMovesVersion() async {
        libraryIndexState.reset()
        let cfg = config(port: 17102)
        _ = await LibraryIndex.shared.movies(config: cfg)
        let before = await LibraryIndex.shared.version(for: .radarr, config: cfg)
        await LibraryIndex.shared.invalidate(.radarr, config: cfg)
        #expect(await LibraryIndex.shared.version(for: .radarr, config: cfg) != before)
    }

    @Test("A failed read says so and does not move the version")
    func failedReadIsReported() async {
        libraryIndexState.reset()
        let cfg = config(port: 17103)
        libraryIndexState.failing = true
        let before = await LibraryIndex.shared.version(for: .radarr, config: cfg)
        let read = await LibraryIndex.shared.moviesRead(config: cfg)
        #expect(read.failed)
        #expect(read.records.isEmpty)
        #expect(await LibraryIndex.shared.version(for: .radarr, config: cfg) == before)
    }

    @Test("Two configs are two libraries with their own versions")
    func configsAreSeparate() async {
        libraryIndexState.reset()
        let a = config(port: 17105)
        let b = config(port: 17106)
        let recordsA = await LibraryIndex.shared.movies(config: a)
        let recordsB = await LibraryIndex.shared.movies(config: b)
        #expect(recordsA.first?.tmdbId == 17105)
        #expect(recordsB.first?.tmdbId == 17106)
        #expect(await LibraryIndex.shared.version(for: .radarr, config: a) != LibraryIndex.shared.version(for: .radarr, config: b))
    }

    @Test("An unconfigured arr reads as empty without a request")
    func unconfiguredIsInert() async {
        libraryIndexState.reset()
        let read = await LibraryIndex.shared.moviesRead(config: ServiceConfig(enabled: false, baseURL: "", apiKey: "", username: "", password: ""))
        #expect(read.records.isEmpty)
        #expect(!read.failed)
        #expect(libraryIndexState.movieHits == 0)
    }
}
