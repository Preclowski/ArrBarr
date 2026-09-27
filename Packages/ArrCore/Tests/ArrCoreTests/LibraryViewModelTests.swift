import Testing
import Foundation
@testable import ArrCore

/// The grid used to keep its own 5-minute TTL, so an add invalidated the
/// ownership index and the grid went on showing "not owned" for minutes. It
/// now re-unifies exactly when `LibraryIndex.version(for:)` moves.
private final class LibraryVMStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _movieHits = 0
    /// Ports whose arr is "down" — every request to them answers 500. Keyed by
    /// port so one test can hold a healthy arr and a broken one side by side.
    private var _failingPorts = Set<Int>()
    var movieHits: Int { lock.lock(); defer { lock.unlock() }; return _movieHits }
    func countMovie() { lock.lock(); defer { lock.unlock() }; _movieHits += 1 }
    func fail(port: Int) { lock.lock(); defer { lock.unlock() }; _failingPorts.insert(port) }
    func heal(port: Int) { lock.lock(); defer { lock.unlock() }; _failingPorts.remove(port) }
    func isFailing(port: Int?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return port.map(_failingPorts.contains) ?? false
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _movieHits = 0
        _failingPorts.removeAll()
    }
}

private let libraryVMState = LibraryVMStubState()

private let libraryVMTransport = ScriptedTransport { request in
    let url = request.url
    guard url.host == "libraryvm.test" else { throw URLError(.cannotConnectToHost) }
    if url.path.hasSuffix("/movie") { libraryVMState.countMovie() }
    if libraryVMState.isFailing(port: url.port) { return .init(status: 500, "{}") }
    if url.path.hasSuffix("/movie") {
        return .init(#"[{"id":1,"tmdbId":603,"title":"The Matrix","year":1999,"hasFile":true,"monitored":true}]"#)
    }
    // qualityprofile, alttitle, anything else the load touches.
    return .init("[]")
}

@Suite("LibraryViewModel", .serialized, .gateway(libraryVMTransport))
@MainActor
struct LibraryViewModelTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://libraryvm.test:\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A second load with an unchanged index version does not refetch")
    func stableVersionSkipsReload() async {
        libraryVMState.reset()

        let vm = LibraryViewModel()
        let cfg = config(port: 17301)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(vm.entries[.radarr]?.count == 1)
        #expect(libraryVMState.movieHits == 1)

        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(libraryVMState.movieHits == 1)
    }

    @Test("Invalidating the index makes the next load re-unify")
    func versionChangeTriggersReload() async {
        libraryVMState.reset()

        let vm = LibraryViewModel()
        let cfg = config(port: 17302)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        await LibraryIndex.shared.invalidate(.radarr)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(libraryVMState.movieHits == 2)
        #expect(vm.entries[.radarr]?.count == 1)
    }

    @Test("force invalidates the index first, so ⌘R really refetches")
    func forceInvalidatesFirst() async {
        libraryVMState.reset()

        let vm = LibraryViewModel()
        let cfg = config(port: 17303)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        await vm.loadIfNeeded(source: .radarr, config: cfg, force: true)
        #expect(libraryVMState.movieHits == 2)
    }

    @Test("A failed refetch keeps the grid up and retries on the next load")
    func failedRefetchKeepsEntriesAndRetries() async {
        libraryVMState.reset()

        let vm = LibraryViewModel()
        await vm.loadIfNeeded(source: .radarr, config: config(port: 17304))
        #expect(vm.entries[.radarr]?.count == 1)
        #expect(libraryVMState.movieHits == 1)

        // A different arr that is down: the index has no snapshot for it, so
        // the failed fetch comes back EMPTY rather than stale. Committing that
        // is what used to blank a grid that was fine a second ago.
        let broken = config(port: 17305)
        libraryVMState.fail(port: 17305)
        await vm.loadIfNeeded(source: .radarr, config: broken, force: true)
        #expect(vm.entries[.radarr]?.count == 1)
        // Something IS on screen, so this is not the tab's error state.
        #expect(!vm.loadFailed.contains(.radarr))

        // …and the failed load must not count as done: the next one retries.
        libraryVMState.heal(port: 17305)
        let hitsBefore = libraryVMState.movieHits
        await vm.loadIfNeeded(source: .radarr, config: broken)
        #expect(libraryVMState.movieHits == hitsBefore + 1)
        #expect(vm.entries[.radarr]?.count == 1)
    }

    @Test("A later session paints the saved grid before the arr answers")
    func snapshotPaintsBeforeTheFetch() async {
        libraryVMState.reset()

        let cfg = config(port: 17321)
        await LibraryViewModel().loadIfNeeded(source: .radarr, config: cfg)
        // No hit-count assertion: the cache-first paint may schedule a
        // revalidating pass behind it, and whether that has landed by now is a
        // race. What matters is the snapshot below.

        // The snapshot is written off the caller's thread; wait for it rather
        // than racing it.
        for _ in 0..<40 where await LibrarySnapshotStore.load(.radarr, fingerprint: cfg.identityFingerprint) == nil {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        // A new session against an arr that is now DOWN: nothing can be
        // fetched, and the grid must still come up off the saved projection
        // rather than showing the error state.
        libraryVMState.fail(port: 17321)
        await LibraryIndex.shared.invalidate(.radarr)
        let next = LibraryViewModel()
        await next.loadIfNeeded(source: .radarr, config: cfg)
        #expect(next.entries[.radarr]?.count == 1)
        #expect(!next.loadFailed.contains(.radarr))
    }

    @Test("An unreachable arr with nothing cached sets loadFailed")
    func unreachableSetsLoadFailed() async {
        // The transport refuses this host, so every request errors.
        let vm = LibraryViewModel()
        let cfg = ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:1/",
                                apiKey: "k", username: "", password: "")
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(vm.loadFailed.contains(.radarr))
        #expect(vm.entries[.radarr] == nil)
    }
}
