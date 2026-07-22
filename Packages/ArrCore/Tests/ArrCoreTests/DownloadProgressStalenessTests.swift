import Foundation
import Testing
@testable import ArrCore

/// Mutable script for the stub below: whether the client is answering, and how
/// many times it was asked.
private final class StubState: @unchecked Sendable {
    var failing = false
    var requests = 0
    /// SABnzbd's queue shape — one slot, 90% done.
    var body = Data("""
        {"queue":{"paused":false,"slots":[
          {"nzo_id":"nzo_abc","filename":"Some.Release","status":"Downloading",
           "mb":"100","mbleft":"10","percentage":"90","timeleft":"0:01:00"}
        ]}}
        """.utf8)
}

/// Stubs `URLSession.shared` (which is what `SabnzbdClient` uses, and therefore
/// what `DownloadProgressService` builds its sources on) for ONE host, so
/// suites running in parallel keep their own traffic.
private final class StaleProgressStub: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    static let host = "sab.stale.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = Self.state
        state.requests += 1
        let url = request.url ?? URL(string: "about:blank")!
        let status = state.failing ? 500 : 200
        let body = state.failing ? Data("down".utf8) : state.body
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Stopping a download client while the arr stays reachable used to freeze
/// every matching progress bar on the client's last reported value — for ever,
/// with no visual cue, because the cache was served unconditionally. It now
/// ages out and the queue falls back to the arr's own (still advancing)
/// progress.
///
/// `.serialized` + a host-scoped stub: the protocol class is registered
/// globally so it reaches `URLSession.shared`, and the shared `StubState` must
/// not be scripted by two tests at once.
@Suite("Download-progress cache staleness", .serialized)
struct DownloadProgressStalenessTests {

    private var sabConfig: ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://\(StaleProgressStub.host):8080",
                      apiKey: "test-key", username: "", password: "")
    }

    private var configs: [ServiceKind: ServiceConfig] { [.sabnzbd: sabConfig] }

    /// Registers the stub and resets the script, restoring both afterwards.
    private func withStub<T>(_ body: () async throws -> T) async throws -> T {
        URLProtocol.registerClass(StaleProgressStub.self)
        StaleProgressStub.state.failing = false
        StaleProgressStub.state.requests = 0
        defer {
            URLProtocol.unregisterClass(StaleProgressStub.self)
            StaleProgressStub.state.failing = false
        }
        return try await body()
    }

    /// The regression: within the `ttl` de-bounce the cache is served without a
    /// re-fetch, and that path used to hand back entries of any age.
    @Test("A cache older than the freshness window stops overriding the arr")
    func staleCacheIsNotServed() async throws {
        try await withStub {
            // ttl deliberately long: the second call must take the de-bounce
            // path, so this pins the age check rather than a failed re-fetch.
            let service = DownloadProgressService(ttl: 60, maxCacheAge: 0.3)

            let fresh = await service.snapshot(configs: configs)
            #expect(fresh["nzo_abc"]?.progress == 0.9)

            try await Task.sleep(for: .milliseconds(450))

            let stale = await service.snapshot(configs: configs)
            #expect(stale.isEmpty, "an aged-out entry must not override the arr's progress")
            // One round-trip only — proving the de-bounce path is the one that
            // returned nothing, not a second fetch that came back empty.
            #expect(StaleProgressStub.state.requests == 1)
        }
    }

    /// The other consumer of the freshness window: a cycle in which every
    /// client failed keeps the last-known map so a blip doesn't snap the bars
    /// back — but the kept map still has to age out.
    @Test("A dead client's last-known map ages out instead of pinning the bars")
    func lastKnownMapAgesOut() async throws {
        try await withStub {
            let service = DownloadProgressService(ttl: 0.05, maxCacheAge: 0.3)

            let fresh = await service.snapshot(configs: configs)
            #expect(fresh["nzo_abc"]?.progress == 0.9)

            StaleProgressStub.state.failing = true
            try await Task.sleep(for: .milliseconds(450))

            let stale = await service.snapshot(configs: configs)
            #expect(stale.isEmpty)
            #expect(StaleProgressStub.state.requests == 2)
        }
    }

    /// …and the behaviour the age limit must NOT undo: a transient failure
    /// inside the window still serves the last-known map, so a one-off blip
    /// doesn't make every bar jump backwards to the arr's value.
    @Test("A transient failure inside the window still serves the last-known map")
    func freshCacheSurvivesABlip() async throws {
        try await withStub {
            let service = DownloadProgressService(ttl: 0.05, maxCacheAge: 60)

            let fresh = await service.snapshot(configs: configs)
            #expect(fresh["nzo_abc"]?.progress == 0.9)

            StaleProgressStub.state.failing = true
            try await Task.sleep(for: .milliseconds(100))

            let kept = await service.snapshot(configs: configs)
            #expect(kept["nzo_abc"]?.progress == 0.9)
        }
    }

    /// No client configured at all means no overlay — the queue keeps the arr
    /// values and nothing is dialled. Cheap guard that the age check didn't
    /// turn into "always return the cache".
    @Test("No configured client yields no overlay and no traffic")
    func nothingConfigured() async throws {
        try await withStub {
            let service = DownloadProgressService(ttl: 60, maxCacheAge: 60)
            let snapshot = await service.snapshot(configs: [:])
            #expect(snapshot.isEmpty)
            #expect(StaleProgressStub.state.requests == 0)
        }
    }
}
