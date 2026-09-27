import Foundation
import Testing
@testable import MediaKit

struct Row: Codable, Sendable, Equatable { let id: Int; let title: String }

@Suite struct ResourceStoreTests {
    @Test func secondReadInsideTTLIsZeroRequests() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"Big Buck Bunny"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        let first = try await kit.store.read(r)
        #expect(first.origin == .network && first.value.first?.title == "Big Buck Bunny")
        let second = try await kit.store.read(r)
        #expect(second.origin == .memory && !second.isStale)
        #expect(kit.transport.count == 1)
        kit.clock.advance(by: .seconds(61))
        kit.transport.answer("fetchQueue", json: "[]")
        let third = try await kit.store.read(r)
        #expect(third.origin == .network && third.value.isEmpty)
        #expect(kit.transport.count == 2)
    }

    @Test func aVolatileRowIsServedInsideItsTTL() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        kit.transport.answer("fetchReleases", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchReleases", path: "/api/v3/release", freshness: .volatile)
        _ = try await kit.store.read(r)
        kit.clock.advance(by: .seconds(2))
        let second = try await kit.store.read(r)
        #expect(second.origin == .memory && kit.transport.count == 1)
        kit.clock.advance(by: .seconds(4))
        kit.transport.answer("fetchReleases", json: "[]")
        _ = try await kit.store.read(r)
        #expect(kit.transport.count == 2)
    }

    @Test func maxAgeTightensTheClassTTL() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchLibrary", json: "[]")
        kit.transport.answer("fetchLibrary", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchLibrary", path: "/api/v3/movie", freshness: .warm)
        _ = try await kit.store.read(r)
        kit.clock.advance(by: .seconds(30))
        _ = try await kit.store.read(r, maxAge: .seconds(10))
        #expect(kit.transport.count == 2)
    }

    @Test func concurrentReadersCoalesceIntoOneRequest() async throws {
        let kit = try await TestKit()
        kit.transport.delay = .milliseconds(50)
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        async let a = kit.store.read(r)
        async let b = kit.store.read(r)
        async let c = kit.store.read(r)
        _ = try await (a, b, c)
        #expect(kit.transport.count == 1)
        #expect(kit.telemetry.cacheCounters(for: TestKit.radarr).coalesced == 2)
    }

    @Test func cancellingOneCoalescedReaderLeavesTheOtherItsValue() async throws {
        let kit = try await TestKit()
        kit.transport.delay = .milliseconds(200)
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"Elephants Dream"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        let leaving = Task { try await kit.store.read(r) }
        let staying = Task { try await kit.store.read(r) }
        try await eventually { kit.transport.count == 1 && kit.telemetry.cacheCounters(for: TestKit.radarr).coalesced == 1 }
        leaving.cancel()
        let served = try await staying.value
        #expect(served.value.first?.title == "Elephants Dream")
        _ = try? await leaving.value
        #expect(kit.transport.count == 1 && kit.transport.cancelledSends == 0)
    }

    @Test(arguments: [1, 2])
    func cancellingEveryReaderCancelsTheRequestAndCommitsNothing(readers: Int) async throws {
        let kit = try await TestKit()
        kit.transport.delay = .seconds(10)
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        let tasks = (0..<readers).map { _ in Task { try await kit.store.read(r) } }
        try await eventually { kit.transport.count == 1 && kit.telemetry.cacheCounters(for: TestKit.radarr).coalesced == readers - 1 }
        for task in tasks { task.cancel() }
        for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
        #expect(kit.transport.count == 1 && kit.transport.cancelledSends == 1)
        await #expect(throws: MediaKitError.self) { try await kit.store.read(r, policy: .cacheOnly) }
    }

    @Test func invalidationMakesTheRowStaleNotGone() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"Sintel"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        let before = kit.store.revision.all
        await kit.store.invalidate([.collection(.queue, TestKit.radarr)], reason: .event)
        #expect(kit.store.revision.all > before)
        kit.transport.fallback = { _ in throw URLError(.cannotConnectToHost) }
        let served = try await kit.store.read(r)
        #expect(served.isStale && served.degraded?.caseName == "unreachable" && served.value.first?.title == "Sintel")
        #expect(kit.telemetry.cacheCounters(for: TestKit.radarr).staleServed == 1)
    }

    @Test func breakerOpenServesStaleAfterOneActorHop() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        kit.transport.fallback = { _ in throw URLError(.cannotConnectToHost) }
        kit.clock.advance(by: .seconds(61))
        for _ in 0..<3 { _ = try? await kit.pipeline.send(kit.plan("fetchHealth", path: "/api/v3/health")) }
        let sent = kit.transport.count
        let served = try await kit.store.read(r)
        #expect(served.isStale && served.degraded?.caseName == "breakerOpen")
        #expect(kit.transport.count == sent)
    }

    @Test func mustRevalidateNeverSubstitutesAStaleRow() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        kit.transport.fallback = { _ in throw URLError(.timedOut) }
        await #expect(throws: MediaKitError.self) { try await kit.store.read(r, policy: .mustRevalidate) }
    }

    @Test func staleWhileRevalidateReturnsNowAndCommitsLater() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"old"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        kit.clock.advance(by: .seconds(61))
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"new"}]"#)
        let stale = try await kit.store.read(r, policy: .staleWhileRevalidate)
        #expect(stale.isStale && stale.value[0].title == "old")
        try await Task.sleep(for: .milliseconds(100))
        let fresh = try await kit.store.read(r)
        #expect(fresh.value[0].title == "new" && fresh.origin == .memory)
    }

    /// TTL expiry means "possibly old" — serve it. An invalidation means "known changed" — serving it would
    /// show the user the state they just changed away from (an imported title still listed as missing).
    @Test func staleWhileRevalidateRefetchesAnInvalidatedRow() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"old"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"new"}]"#)
        await kit.store.invalidate([.collection(.queue, TestKit.radarr)], reason: .event)
        let served = try await kit.store.read(r, policy: .staleWhileRevalidate)
        #expect(served.origin == .network && !served.isStale && served.value[0].title == "new")
    }

    /// The refetch is not a promise the network will answer: a dead host still gets the last known rows.
    @Test func anInvalidatedRowIsStillServedWhenTheRefetchFails() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"old"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        await kit.store.invalidate([.collection(.queue, TestKit.radarr)], reason: .event)
        kit.transport.fallback = { _ in throw URLError(.cannotConnectToHost) }
        let served = try await kit.store.read(r, policy: .staleWhileRevalidate)
        #expect(served.isStale && served.degraded != nil && served.value[0].title == "old")
    }

    @Test func cacheOnlyNeverTouchesTheNetwork() async throws {
        let kit = try await TestKit()
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        await #expect(throws: MediaKitError.self) { try await kit.store.read(r, policy: .cacheOnly) }
        #expect(kit.transport.count == 0)
    }

    @Test func volatileRowsNeverReachSQLite() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchReleases", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchReleases", path: "/api/v3/release", freshness: .volatile)
        _ = try await kit.store.read(r)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await kit.database!.scalar("SELECT COUNT(*) FROM entries WHERE class = 0") == 0)
        #expect(try await kit.database!.scalar("SELECT COUNT(*) FROM entries") == 0)
    }

    @Test func rowsFromAnotherFingerprintAreInvisible() async throws {
        let dir = Temp.directory()
        let kit = try await TestKit(database: .file(in: dir))
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"x"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        await kit.database!.flush()
        let baseURL = URL(string: "http://radarr.fixture.invalid:8080")!
        await kit.registry.apply([InstanceDescriptor(id: TestKit.radarr, baseURL: baseURL, generation: "g2"),
                                  InstanceDescriptor(id: TestKit.sonarr, baseURL: URL(string: "http://sonarr.fixture.invalid:8080")!, generation: "g1")])
        await #expect(throws: MediaKitError.self) { try await kit.store.read(r, policy: .cacheOnly) }
    }

    @Test func coldStartReadsDiskWithoutARequest() async throws {
        let dir = Temp.directory()
        let first = try await TestKit(database: .file(in: dir))
        first.transport.answer("fetchQueue", json: #"[{"id":7,"title":"Tears of Steel"}]"#)
        let r: Resource<[Row]> = first.resource("fetchQueue")
        _ = try await first.store.read(r)
        await first.database!.flush()
        let second = try await TestKit(database: .file(in: dir))
        let served = try await second.store.read(r, policy: .cacheOnly)
        #expect(served.origin == .disk && served.value[0].id == 7)
        #expect(second.transport.count == 0)
    }

    @Test func commandInvalidatesItsTags() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: "[]")
        kit.transport.answer("pause", json: "{}")
        kit.transport.answer("fetchQueue", json: "[]")
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        _ = try await kit.store.read(r)
        var mutable = kit.plan("pause", path: "/api/v3/queue/{id}")
        mutable.method = "DELETE"
        let plan = mutable
        let command = Command(name: plan.operation, instance: TestKit.radarr, invalidates: [.collection(.queue, TestKit.radarr)]) { ctx in
            _ = try await ctx.send(plan)
            return CommandReceipt(acceptedAt: ctx.clock.now)
        }
        _ = try await kit.store.run(command)
        _ = try await kit.store.read(r)
        #expect(kit.transport.operations == ["fetchQueue", "pause", "fetchQueue"])
    }

    @Test func chunkedBatchIsOneRequestPerChunk() async throws {
        let kit = try await TestKit()
        kit.transport.fallback = { request in
            let ids = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name == "movieId" }.map { $0.value! }
            let rows = ids.map { #"{"id":\#($0),"title":"m\#($0)"}"# }.joined(separator: ",")
            return ScriptedTransport.Answer(status: 200, body: Data("[\(rows)]".utf8))
        }
        let batch = BatchResource<Int, Row>(.chunked(max: 10, make: { ids in
            var plan = kit.plan("fetchMovieFiles", path: "/api/v3/moviefile")
            plan.query = ids.map { RequestPlan.QueryItem("movieId", String($0)) }
            return Resource<[Row]>.json(plan, tags: [.collection(.library, TestKit.radarr)], freshness: .warm)
        }, identify: { $0.id }))
        let result = await kit.store.batch(batch, keys: Array(1...25))
        #expect(result.count == 25 && kit.transport.count == 3)
        if case let .success(rows)? = result[13] { #expect(rows.first?.title == "m13") } else { Issue.record("missing 13") }
    }

    @Test func observeEmitsOnInvalidationAndCommit() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"a"}]"#)
        let r: Resource<[Row]> = kit.resource("fetchQueue")
        var iterator = kit.store.observe(r).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.value[0].title == "a")
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"b"}]"#)
        await kit.store.invalidate([.collection(.queue, TestKit.radarr)], reason: .event)
        let second = await iterator.next()
        #expect(second?.value[0].title == "b")
    }
}
