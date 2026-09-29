import Foundation
import Testing
@testable import MediaKit

@Suite struct HostGovernorTests {
    let host = Host(URL(string: "http://radarr.fixture.invalid:8080")!)

    func governor(_ edit: (inout HostGovernor.Limits) -> Void = { _ in }) -> (HostGovernor, TestClock, TelemetryRecorder) {
        var limits = HostGovernor.Limits()
        edit(&limits)
        let clock = TestClock()
        let telemetry = TelemetryRecorder(clock: clock)
        return (HostGovernor(defaults: limits, clock: clock, telemetry: telemetry, log: NoLog()), clock, telemetry)
    }

    @Test func breakerOpensAfterThreeFailuresAndHalfOpensLater() async throws {
        let (g, clock, telemetry) = governor()
        for _ in 0..<3 {
            let slot = try await g.enter(host, kind: .radarr, priority: .interactive)
            await g.leave(slot, outcome: .transportFailure(.unreachable(host, .refused)))
        }
        guard case .down = g.health(of: host) else { Issue.record("expected down, got \(g.health(of: host))"); return }
        #expect(telemetry.counters(for: host).breakerOpens == 1)
        await #expect(throws: MediaKitError.self) { try await g.enter(host, kind: .radarr, priority: .interactive) }
        clock.advance(by: .seconds(31))
        let probe = try await g.enter(host, kind: .radarr, priority: .interactive)
        await #expect(throws: MediaKitError.self) { try await g.enter(host, kind: .radarr, priority: .background) }
        await g.leave(probe, outcome: .success)
        #expect(g.health(of: host) == .healthy)
    }

    @Test func serverErrorsAreNotStrikes() async throws {
        let (g, _, _) = governor()
        for _ in 0..<5 {
            let slot = try await g.enter(host, kind: .radarr, priority: .interactive)
            await g.leave(slot, outcome: .success)
        }
        #expect(g.health(of: host) == .healthy)
    }

    @Test func rateLimitBlocksOnlyThatHost() async throws {
        let (g, clock, _) = governor()
        let other = Host(URL(string: "http://sonarr.fixture.invalid:8989")!)
        let slot = try await g.enter(host, kind: .radarr, priority: .interactive)
        await g.leave(slot, outcome: .retryAfter(.seconds(20)))
        await #expect(throws: MediaKitError.self) { try await g.enter(host, kind: .radarr, priority: .interactive) }
        _ = try await g.enter(other, kind: .sonarr, priority: .interactive)
        clock.advance(by: .seconds(21))
        _ = try await g.enter(host, kind: .radarr, priority: .interactive)
    }

    @Test func backgroundShareCannotStarveInteractive() async throws {
        let (g, _, _) = governor()
        var background: [HostGovernor.Slot] = []
        for _ in 0..<2 { background.append(try await g.enter(host, kind: .radarr, priority: .background)) }
        let blocked = Task { try await g.enter(host, kind: .radarr, priority: .background) }
        try await Task.sleep(for: .milliseconds(20))
        let interactive = try await g.enter(host, kind: .radarr, priority: .interactive)
        await g.leave(interactive, outcome: .success)
        await g.leave(background[0], outcome: .success)
        _ = try await blocked.value
    }

    @Test func sessionLaneNeverWaitsBehindRegularSlots() async throws {
        let (g, _, _) = governor()
        var held: [HostGovernor.Slot] = []
        for _ in 0..<3 { held.append(try await g.enter(host, kind: .qbittorrent, priority: .interactive)) }
        let fourth = Task { try await g.enter(host, kind: .qbittorrent, priority: .interactive) }
        try await Task.sleep(for: .milliseconds(20))
        let session = try await g.enter(host, kind: .qbittorrent, priority: .session)
        await g.leave(session, outcome: .success)
        for slot in held { await g.leave(slot, outcome: .success) }
        _ = try await fourth.value
    }

    @Test func cancelledWaiterLeavesTheQueue() async throws {
        let (g, _, _) = governor { $0.maxConcurrent = 2; $0.reservedSessionSlots = 1 }
        let held = try await g.enter(host, kind: .radarr, priority: .interactive)
        let waiting = Task { try await g.enter(host, kind: .radarr, priority: .interactive) }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await g.leave(held, outcome: .success)
        _ = try await g.enter(host, kind: .radarr, priority: .interactive)
    }

    @Test(arguments: [2, 6])
    func hundredDistinctReadsNeverExceedTheHostLimit(limit: Int) async throws {
        var limits = HostGovernor.Limits()
        limits.maxConcurrent = limit
        limits.reservedSessionSlots = 0
        let kit = try await TestKit(limits: limits)
        kit.transport.delay = .milliseconds(20)
        kit.transport.fallback = { _ in ScriptedTransport.Answer(status: 200, body: Data("[]".utf8)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<100 {
                let r = Resource<[Row]>.json(kit.plan("fetchMovie", path: "/api/v3/movie", query: [RequestPlan.QueryItem("id", String(id))]),
                                             tags: [.collection(.library, TestKit.radarr)], freshness: .live)
                group.addTask { _ = try await kit.store.read(r) }
            }
            try await group.waitForAll()
        }
        #expect(kit.transport.count == 100)
        #expect(kit.transport.maxInFlight == limit)
    }

    @Test func wakeHalfOpensDownHosts() async throws {
        let (g, clock, _) = governor()
        for _ in 0..<3 {
            let slot = try await g.enter(host, kind: .radarr, priority: .interactive)
            await g.leave(slot, outcome: .transportFailure(.unreachable(host, .dns)))
        }
        await g.noteWake(at: clock.now)
        _ = try await g.enter(host, kind: .radarr, priority: .interactive)
    }

    @Test func minimumIntervalSpacesSends() async throws {
        let (g, clock, _) = governor { $0.minimumInterval = .milliseconds(250) }
        let first = try await g.enter(host, kind: .tmdb, priority: .interactive)
        await g.leave(first, outcome: .success)
        let second = Task { try await g.enter(host, kind: .tmdb, priority: .interactive) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(clock.pendingSleepers == 1)
        clock.advance(by: .milliseconds(300))
        _ = try await second.value
    }

    @Test func aQueuedSendIsSpacedToo() async throws {
        let (g, clock, _) = governor { $0.minimumInterval = .milliseconds(250); $0.maxConcurrent = 1; $0.reservedSessionSlots = 0 }
        let first = try await g.enter(host, kind: .tmdb, priority: .interactive)
        let queued = Task { try await g.enter(host, kind: .tmdb, priority: .interactive) }
        try await Task.sleep(for: .milliseconds(20))
        await g.leave(first, outcome: .success)
        try await Task.sleep(for: .milliseconds(20))
        #expect(clock.pendingSleepers == 1)
        clock.advance(by: .milliseconds(300))
        _ = try await queued.value
    }
}
