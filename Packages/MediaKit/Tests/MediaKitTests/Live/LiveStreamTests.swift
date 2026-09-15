import Foundation
import Testing
@testable import MediaKit

struct Item: Codable, Sendable, Equatable, LivePatchable {
    let id: String
    var status: String
    func applying(_ change: PendingEffect.Change) -> Item? {
        if case let .status(s) = change { var c = self; c.status = s; return c }
        return nil
    }
}

@Suite struct LiveStreamTests {
    func stream(_ kit: TestKit, fetch: @escaping LiveStream<Item>.Fetch) -> LiveStream<Item> {
        LiveStream<Item>(id: .queue, instances: [TestKit.radarr], policy: .queue, pipeline: kit.pipeline, database: kit.database,
                         clock: kit.clock, telemetry: kit.telemetry, log: NoLog(), elementID: { $0.id }, fetch: fetch)
    }

    @Test func fullFailureKeepsElementsInsideGraceThenStale() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let fail = Flag()
        let s = stream(kit) { _, _, _ in
            if fail.value { throw MediaKitError.unreachable(Host(URL(string: "http://x")!), .refused) }
            return [Item(id: "a", status: "downloading")]
        }
        await s.refreshNow()
        #expect(s.last()?.elements.count == 1)
        fail.value = true
        await s.refreshNow()
        #expect(s.last()?.elements.count == 1 && s.last()?.isStale == false && s.last()?.partial == [TestKit.radarr])
        kit.clock.advance(by: .seconds(61))
        await s.refreshNow()
        #expect(s.last()?.isStale == true && s.last()?.elements.count == 1)
    }

    @Test func pendingEffectsOverlayUntilTheSourceAgrees() async throws {
        let kit = try await TestKit()
        let status = Box("downloading")
        let s = stream(kit) { _, _, _ in [Item(id: "a", status: status.value)] }
        await s.refreshNow()
        await s.apply(PendingEffect(elementID: "a", change: .status("paused"), expiresAt: kit.clock.now.addingTimeInterval(30)))
        #expect(s.last()?.elements.first?.status == "paused" && s.last()?.pending.count == 1)
        status.value = "paused"
        await s.refreshNow()
        #expect(s.last()?.pending.isEmpty == true && s.last()?.elements.first?.status == "paused")
    }

    @Test func keepAliveGhostsARowTheSourceDropped() async throws {
        let kit = try await TestKit()
        let rows = Box([Item(id: "a", status: "queued")])
        let s = stream(kit) { _, _, _ in rows.value }
        await s.refreshNow()
        rows.value = []
        await s.apply(PendingEffect(elementID: "a", change: .keepAlive, expiresAt: kit.clock.now.addingTimeInterval(30)))
        await s.refreshNow()
        #expect(s.last()?.elements.map(\.id) == ["a"])
    }

    @Test func snapshotIsAvailableBeforeTheFirstRequest() async throws {
        let dir = Temp.directory()
        let first = try await TestKit(database: .file(in: dir))
        let s1 = stream(first) { _, _, _ in [Item(id: "a", status: "downloading")] }
        await s1.refreshNow()
        await first.database!.flush()
        let second = try await TestKit(database: .file(in: dir))
        let calls = Counter()
        let s2 = stream(second) { _, _, _ in calls.increment(); return [] }
        await s2.start()
        #expect(s2.last()?.isFromSnapshot == true && s2.last()?.elements.first?.id == "a")
        await s2.stop()
    }

    @Test func pushCoverageSkipsThePoll() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [] }
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        let afterStart = calls.value
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == afterStart + 1)
        kit.clock.advance(by: .seconds(31))
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == afterStart + 1)
        await s.stop()
    }
}

final class Flag: @unchecked Sendable { var value = false }
final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
