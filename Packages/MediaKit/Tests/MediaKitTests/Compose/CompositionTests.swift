import Foundation
import Testing
@testable import MediaKit

@Suite struct CompositionTests {
    @Test func provenanceAndMemo() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"a"}]"#)
        kit.transport.answer("fetchHealth", json: "[]")
        let engine = CompositionEngine(store: kit.store, identity: kit.identity, capabilities: kit.capabilities, clock: kit.clock, telemetry: kit.telemetry)
        let queue: Resource<[Row]> = kit.resource("fetchQueue")
        let health: Resource<[Row]> = kit.resource("fetchHealth", path: "/api/v3/health", tags: [.collection(.health, TestKit.radarr)])
        let composed = try await engine.compose("popover") { ctx in
            async let q = ctx.read(queue)
            async let h = ctx.optional(health)
            return try await q.count + (await h?.count ?? 0)
        }
        #expect(composed.value == 1 && composed.provenance.isComplete)
        #expect(composed.provenance.tags.contains(.collection(.health, TestKit.radarr)))
        let again = try await engine.compose("popover") { _ in Issue.record("memo missed"); return 0 }
        #expect(again.value == 1)
        await kit.store.invalidate([.collection(.health, TestKit.radarr)], reason: .event)
        kit.transport.answer("fetchHealth", json: #"[{"id":2,"title":"warn"}]"#)
        let rebuilt = try await engine.compose("popover") { ctx in try await ctx.read(queue).count + (await ctx.optional(health)?.count ?? 0) }
        #expect(rebuilt.value == 2)
    }

    @Test func partialResultsAreNotMemoised() async throws {
        let kit = try await TestKit()
        kit.transport.fallback = { _ in throw URLError(.cannotConnectToHost) }
        let engine = CompositionEngine(store: kit.store, identity: kit.identity, capabilities: kit.capabilities, clock: kit.clock, telemetry: kit.telemetry)
        let queue: Resource<[Row]> = kit.resource("fetchQueue")
        let first = try await engine.compose("x") { ctx in await ctx.optional(queue)?.count ?? -1 }
        #expect(first.value == -1 && first.provenance.isOffline)
        kit.transport.fallback = { _ in ScriptedTransport.Answer(status: 200, body: Data("[]".utf8)) }
        kit.clock.advance(by: .seconds(31))   // the breaker opened on the three failed attempts
        let second = try await engine.compose("x") { ctx in await ctx.optional(queue)?.count ?? -1 }
        #expect(second.value == 0)
    }

    @Test func observeRebuildsOnBump() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchQueue", json: "[]")
        let engine = CompositionEngine(store: kit.store, identity: kit.identity, capabilities: kit.capabilities, clock: kit.clock, telemetry: kit.telemetry)
        let queue: Resource<[Row]> = kit.resource("fetchQueue")
        let box = ComposedBox(engine.observe("obs") { ctx in try await ctx.read(queue).count }.makeAsyncIterator())
        #expect(await box.next()?.value == 0)
        kit.transport.answer("fetchQueue", json: #"[{"id":1,"title":"a"}]"#)
        await kit.store.invalidate([.collection(.queue, TestKit.radarr)], reason: .event)
        #expect(await box.next()?.value == 1)
    }
}

final class ComposedBox: @unchecked Sendable {
    var it: AsyncStream<Composed<Int>>.AsyncIterator
    init(_ it: AsyncStream<Composed<Int>>.AsyncIterator) { self.it = it }
    func next() async -> Composed<Int>? { await it.next() }
}
