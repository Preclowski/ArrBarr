import Foundation
import Testing
@testable import MediaKit

struct Item: Codable, Sendable, Equatable, LivePatchable {
    let id: String
    var status: String
    var alias: String? = nil
    /// The id of the row this one took over from.
    var replaces: String? = nil
    func applying(_ change: PendingEffect.Change) -> Item? {
        if case let .status(s) = change { var c = self; c.status = s; return c }
        return nil
    }
    var liveAliases: [String] { alias.map { [$0] } ?? [] }
    func succeeds(_ gone: Item) -> Bool { replaces == gone.id }
}

@Suite struct LiveStreamTests {
    func stream(_ kit: TestKit, instances: [InstanceID] = [TestKit.radarr], policy: LivePolicy = .queue,
                fetch: @escaping LiveStream<Item>.Fetch) -> LiveStream<Item> {
        LiveStream<Item>(id: .queue, instances: instances, policy: policy, pipeline: kit.pipeline, database: kit.database,
                         clock: kit.clock, telemetry: kit.telemetry, log: NoLog(), elementID: { $0.id }, fetch: fetch,
                         isActive: { items in items.contains { $0.status == "downloading" } })
    }

    @Test func aFailedInstanceKeepsItsOwnRowsWhileTheOthersUpdate() async throws {
        let kit = try await TestKit()
        let sonarrDown = Flag()
        let s = stream(kit, instances: [TestKit.radarr, TestKit.sonarr]) { instance, _, _ in
            if instance == TestKit.sonarr {
                if sonarrDown.value { throw MediaKitError.unreachable(Host(URL(string: "http://x")!), .refused) }
                return [Item(id: "s", status: "downloading")]
            }
            return [Item(id: sonarrDown.value ? "r2" : "r1", status: "downloading")]
        }
        await s.refreshNow()
        sonarrDown.value = true
        await s.refreshNow()
        let value = try #require(s.last())
        #expect(Set(value.elements.map(\.id)) == ["r2", "s"])
        #expect(value.partial == [TestKit.sonarr] && value.failures[TestKit.sonarr] != nil)
        #expect(value.slices[TestKit.sonarr]?.elements.map(\.id) == ["s"] && value.slices[TestKit.radarr]?.elements.map(\.id) == ["r2"])
    }

    @Test func refreshNowDuringACycleWaitsForAFetchThatStartedAfterIt() async throws {
        let kit = try await TestKit()
        let gate = Gate()
        let version = Box("old")
        let s = stream(kit) { _, _, _ in
            let seen = version.value
            if seen == "old" { await gate.wait() }
            return [Item(id: "a", status: seen)]
        }
        let first = Task { await s.refreshNow() }
        try await Task.sleep(for: .milliseconds(20))
        version.value = "new"
        let second = Task { await s.refreshNow() }
        try await Task.sleep(for: .milliseconds(20))
        await gate.open()
        await first.value
        await second.value
        #expect(s.last()?.elements.first?.status == "new")
    }

    @Test func thePumpWaitingOnAnotherCallersFetchLetsEffectsIn() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let gate = Gate()
        let s = stream(kit) { _, _, _ in await gate.wait(); return [Item(id: "a", status: "paused")] }
        let refresh = Task { await s.refreshNow() }
        try await Task.sleep(for: .milliseconds(20))
        await s.start()
        try await Task.sleep(for: .milliseconds(20))
        await gate.open()
        let done = Flag()
        Task.detached {
            await refresh.value
            for _ in 0..<20 { await s.apply(PendingEffect(elementID: "a", change: .status("downloading"))) }
            done.value = true
        }
        try await Task.sleep(for: .milliseconds(300))
        // No `await s…` before this: a livelocked actor would hang the suite instead of failing it.
        try #require(done.value)
        #expect(s.last()?.elements.first?.status == "downloading")
        await s.stop()
    }

    @Test func aPushDuringACycleRunsAnotherCycleWithoutWaitingForTheInterval() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let gate = Gate()
        let calls = Counter()
        let s = stream(kit) { _, _, _ in
            calls.increment()
            if calls.value == 1 { await gate.wait() }
            return []
        }
        await s.start()
        try await Task.sleep(for: .milliseconds(20))
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 2)
        await s.stop()
    }

    @Test func aCancelledFetchIsNotAFailure() async throws {
        let kit = try await TestKit()
        let cancel = Flag()
        let s = stream(kit) { _, _, _ in
            if cancel.value { throw CancellationError() }
            return [Item(id: "a", status: "downloading")]
        }
        await s.refreshNow()
        cancel.value = true
        await s.refreshNow()
        #expect(s.last()?.partial.isEmpty == true && s.last()?.elements.map(\.id) == ["a"])
        #expect(s.last()?.revision == 1)
    }

    @Test func theSnapshotKeepsEveryInstancesRows() async throws {
        let dir = Temp.directory()
        let first = try await TestKit(database: .file(in: dir))
        let both = [TestKit.radarr, TestKit.sonarr]
        let s1 = stream(first, instances: both) { instance, _, _ in [Item(id: "1", status: instance.kind.rawValue)] }
        await s1.refreshNow()
        await first.database!.flush()
        let second = try await TestKit(database: .file(in: dir))
        let s2 = stream(second, instances: both) { _, _, _ in [] }
        await s2.start()
        #expect(Set(s2.last()?.elements.map(\.status) ?? []) == ["radarr", "sonarr"])
        await s2.stop()
    }

    @Test func aZeroForegroundIntervalWaitsForAPushInsteadOfSpinning() async throws {
        let kit = try await TestKit()
        var policy = LivePolicy.queue
        policy.foregroundInterval = .zero
        let calls = Counter()
        let s = stream(kit, policy: policy) { _, _, _ in calls.increment(); return [Item(id: "a", status: "downloading")] }
        await s.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 1)
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == 2)
        await s.stop()
    }

    @Test func aPushForAnotherInstanceDoesNotFetch() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [] }
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        let afterStart = calls.value
        await s.notePush(TestKit.sonarr, at: kit.clock.now)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == afterStart)
        await s.stop()
    }

    @Test func theFirstTickWaitsWhenSomeoneJustFetched() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [] }
        await s.refreshNow()
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == 1)
        kit.clock.advance(by: .seconds(31))
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == 2)
        await s.stop()
    }

    @Test func inTheBackgroundAPushCoveredStreamSkipsEvenWhileSomethingDownloads() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [Item(id: "a", status: "downloading")] }
        await s.setActivity(.background)
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        // The push is held to the end of the interval, then answered once.
        kit.clock.advance(by: .seconds(121))
        try await Task.sleep(for: .milliseconds(30))
        let afterPush = calls.value
        kit.clock.advance(by: .seconds(121))
        try await Task.sleep(for: .milliseconds(30))
        #expect(afterPush == 2 && calls.value == afterPush)
        await s.stop()
    }

    @Test func inTheBackgroundAPushCannotAddAFetchInsideTheInterval() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [] }
        await s.setActivity(.background)
        await s.refreshNow()
        await s.start()
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == 1)
        kit.clock.advance(by: .seconds(121))
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == 2)
        await s.stop()
    }

    @Test func anEventThatAsksForNothingStillKeepsCoverageAlive() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [] }
        await s.setActivity(.background)
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        let started = calls.value
        for _ in 0..<5 {
            kit.clock.advance(by: .seconds(121))
            await s.noteAlive(TestKit.radarr, at: kit.clock.now)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(calls.value == started)
        await s.stop()
    }

    @Test func aPendingEffectKeepsTheStreamTickingThoughPushesCoverIt() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let calls = Counter()
        let s = stream(kit) { _, _, _ in calls.increment(); return [Item(id: "a", status: "downloading")] }
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        let started = calls.value
        await s.apply(PendingEffect(elementID: "a", change: .removed, lifetime: .seconds(60)))
        kit.clock.advance(by: .seconds(31))
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == started + 1)
        await s.stop()
    }

    @Test func stopReleasesAPumpWaitingForAPush() async throws {
        let kit = try await TestKit()
        var policy = LivePolicy.queue
        policy.foregroundInterval = .zero
        let calls = Counter()
        let s = stream(kit, policy: policy) { _, _, _ in calls.increment(); return [] }
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        await s.stop()
        await s.start()
        try await Task.sleep(for: .milliseconds(30))
        await s.notePush(TestKit.radarr, at: kit.clock.now)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.value == 3)
        await s.stop()
    }

    @Test func restartingKeepsTheLiveRowsOverTheCheckpoint() async throws {
        let kit = try await TestKit(database: .file(in: Temp.directory()))
        let status = Box("old")
        let s = stream(kit) { _, _, _ in [Item(id: "a", status: status.value)] }
        await s.refreshNow()
        await kit.database!.flush()
        status.value = "new"
        await s.refreshNow()
        await s.start()
        #expect(s.last()?.elements.first?.status == "new" && s.last()?.isFromSnapshot == false)
        await s.stop()
    }

    @Test func anEffectScopedToAnInstancePatchesOnlyThatInstancesRow() async throws {
        let kit = try await TestKit()
        let s = stream(kit, instances: [TestKit.radarr, TestKit.sonarr]) { _, _, _ in [Item(id: "1", status: "downloading")] }
        await s.refreshNow()
        await s.apply(PendingEffect(elementID: "1", instance: TestKit.sonarr, change: .status("paused")))
        let value = try #require(s.last())
        #expect(value.slices[TestKit.sonarr]?.elements.first?.status == "paused")
        #expect(value.slices[TestKit.radarr]?.elements.first?.status == "downloading")
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
        await s.apply(PendingEffect(elementID: "a", change: .status("paused")))
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
        await s.apply(PendingEffect(elementID: "a", change: .keepAlive))
        await s.refreshNow()
        #expect(s.last()?.elements.map(\.id) == ["a"])
    }

    @Test func aStatusEffectGhostsAVanishedRowAtItsPositionUntilTheSourceReturnsIt() async throws {
        let kit = try await TestKit()
        let rows = Box([Item(id: "before", status: "downloading"), Item(id: "q", status: "queued"), Item(id: "after", status: "downloading")])
        let s = stream(kit) { _, _, _ in rows.value }
        await s.refreshNow()
        await s.apply(PendingEffect(elementID: "q", change: .status("downloading")))
        rows.value = [Item(id: "before", status: "downloading"), Item(id: "after", status: "downloading")]
        await s.refreshNow()
        #expect(s.last()?.elements.map(\.id) == ["before", "q", "after"])
        #expect(s.last()?.elements.first { $0.id == "q" }?.status == "downloading")
        rows.value = [Item(id: "before", status: "downloading"), Item(id: "q", status: "downloading"), Item(id: "after", status: "downloading")]
        await s.refreshNow()
        #expect(s.last()?.elements.map(\.id) == ["before", "q", "after"] && s.last()?.pending.isEmpty == true)
    }

    @Test func aNewSuccessorRetiresTheGhostButARowAlreadyThereDoesNot() async throws {
        let kit = try await TestKit()
        let rows = Box([Item(id: "old", status: "downloading", replaces: "p"), Item(id: "p", status: "delay")])
        let s = stream(kit) { _, _, _ in rows.value }
        await s.refreshNow()
        await s.apply(PendingEffect(elementID: "p", change: .status("downloading")))
        rows.value = [Item(id: "old", status: "downloading", replaces: "p")]
        await s.refreshNow()
        #expect(s.last()?.elements.map(\.id) == ["old", "p"])
        rows.value = [Item(id: "old", status: "downloading", replaces: "p"), Item(id: "new", status: "downloading", replaces: "p")]
        await s.refreshNow()
        #expect(s.last()?.elements.map(\.id) == ["old", "new"])
    }

    @Test func aRemovedRowStaysHiddenEvenIfTheSourceBrieflyReturnsIt() async throws {
        let kit = try await TestKit()
        let rows = Box([Item(id: "a", status: "downloading")])
        let s = stream(kit) { _, _, _ in rows.value }
        await s.refreshNow()
        await s.apply(PendingEffect(elementID: "a", change: .removed))
        #expect(s.last()?.elements.isEmpty == true)
        rows.value = []
        await s.refreshNow()
        rows.value = [Item(id: "a", status: "downloading")]
        await s.refreshNow()
        #expect(s.last()?.elements.isEmpty == true)
    }

    @Test func anEffectNamesARowByItsAliasAndBumpsTheOverlay() async throws {
        let kit = try await TestKit()
        let s = stream(kit) { _, _, _ in [Item(id: "7", status: "downloading", alias: "hash")] }
        await s.refreshNow()
        let before = try #require(s.last())
        await s.apply(PendingEffect(elementID: "hash", change: .status("paused")))
        let after = try #require(s.last())
        #expect(after.elements.first?.status == "paused")
        #expect(after.revision == before.revision && after.overlay > before.overlay)
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

    @Test func anEarlyWakeRetiresItsSleeper() async throws {
        let kit = try await TestKit()
        kit.clock.autoAdvance = false
        let s = stream(kit) { _, _, _ in [Item(id: UUID().uuidString, status: "queued")] }
        await s.start()
        try await eventually { kit.clock.pendingSleepers == 1 }
        for _ in 0..<10 {
            await s.notePush(TestKit.radarr, at: kit.clock.now)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await eventually { kit.clock.pendingSleepers <= 1 }
        await s.stop()
    }
}

final class Flag: @unchecked Sendable { var value = false }
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !isOpen { await withCheckedContinuation { waiters.append($0) } } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
