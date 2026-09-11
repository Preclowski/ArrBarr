import Testing
import Foundation
@testable import ArrCore

/// The grid used to keep its own 5-minute TTL, so an add invalidated the
/// ownership index and the grid went on showing "not owned" for minutes. It
/// now re-unifies exactly when `LibraryIndex.version(for:)` moves.
private final class LibraryVMStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _movieHits = 0
    var movieHits: Int { lock.lock(); defer { lock.unlock() }; return _movieHits }
    func countMovie() { lock.lock(); defer { lock.unlock() }; _movieHits += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; _movieHits = 0 }
}

private final class LibraryVMStub: URLProtocol, @unchecked Sendable {
    static let state = LibraryVMStubState()
    static let host = "libraryvm.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "about:blank")!
        let body: String
        if url.path.hasSuffix("/movie") {
            Self.state.countMovie()
            body = #"[{"id":1,"tmdbId":603,"title":"The Matrix","year":1999,"hasFile":true,"monitored":true}]"#
        } else {
            // qualityprofile, alttitle, anything else the load touches.
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

@Suite("LibraryViewModel", .serialized)
@MainActor
struct LibraryViewModelTests {

    private func config(port: Int) -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(LibraryVMStub.host):\(port)",
                      apiKey: "test-key", username: "", password: "")
    }

    @Test("A second load with an unchanged index version does not refetch")
    func stableVersionSkipsReload() async {
        LibraryVMStub.state.reset()
        URLProtocol.registerClass(LibraryVMStub.self)
        defer { URLProtocol.unregisterClass(LibraryVMStub.self) }

        let vm = LibraryViewModel()
        let cfg = config(port: 17301)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(vm.entries[.radarr]?.count == 1)
        #expect(LibraryVMStub.state.movieHits == 1)

        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(LibraryVMStub.state.movieHits == 1)
    }

    @Test("Invalidating the index makes the next load re-unify")
    func versionChangeTriggersReload() async {
        LibraryVMStub.state.reset()
        URLProtocol.registerClass(LibraryVMStub.self)
        defer { URLProtocol.unregisterClass(LibraryVMStub.self) }

        let vm = LibraryViewModel()
        let cfg = config(port: 17302)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        await LibraryIndex.shared.invalidate(.radarr)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(LibraryVMStub.state.movieHits == 2)
        #expect(vm.entries[.radarr]?.count == 1)
    }

    @Test("force invalidates the index first, so ⌘R really refetches")
    func forceInvalidatesFirst() async {
        LibraryVMStub.state.reset()
        URLProtocol.registerClass(LibraryVMStub.self)
        defer { URLProtocol.unregisterClass(LibraryVMStub.self) }

        let vm = LibraryViewModel()
        let cfg = config(port: 17303)
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        await vm.loadIfNeeded(source: .radarr, config: cfg, force: true)
        #expect(LibraryVMStub.state.movieHits == 2)
    }

    @Test("An unreachable arr with nothing cached sets loadFailed")
    func unreachableSetsLoadFailed() async {
        // No stub registered for this host at all, so every request errors.
        let vm = LibraryViewModel()
        let cfg = ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:1/",
                                apiKey: "k", username: "", password: "")
        await vm.loadIfNeeded(source: .radarr, config: cfg)
        #expect(vm.loadFailed.contains(.radarr))
        #expect(vm.entries[.radarr] == nil)
    }
}
