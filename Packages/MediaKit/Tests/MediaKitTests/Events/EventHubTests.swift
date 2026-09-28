import Foundation
import Testing
@testable import MediaKit

actor PushRecorder: LiveStreamPushTarget {
    private(set) var pushes: [InstanceID] = []
    private(set) var alive: [InstanceID] = []
    func notePush(_ instance: InstanceID, at: Date) async { pushes.append(instance) }
    func noteAlive(_ instance: InstanceID, at: Date) async { alive.append(instance) }
}

@Suite struct EventHubTests {
    let counts = QueueCounts(total: 3, count: 3, unknown: 0, errors: false, warnings: false)

    @Test func aHiddenPanelIgnoresAQueuePushWhoseCountsHaveNotMovedSinceTheLastFlush() async throws {
        let kit = try await TestKit()
        let hub = EventHub(store: kit.store, clock: kit.clock)
        let recorder = PushRecorder()
        await hub.register(recorder)
        await hub.setForeground(false)
        await hub.ingest(.queueStatus(TestKit.radarr, counts))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.pushes.count == 1)
        await hub.ingest(.queueChanged(TestKit.radarr))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.pushes.count == 1)
        await hub.setForeground(true)
        await hub.ingest(.queueChanged(TestKit.radarr))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.pushes.count == 2)
    }

    @Test func aStreamRegisteredTwiceHearsEachPushOnce() async throws {
        let kit = try await TestKit()
        let hub = EventHub(store: kit.store, clock: kit.clock)
        let recorder = PushRecorder()
        await hub.register(recorder)
        await hub.register(recorder)
        await hub.ingest(.queueChanged(TestKit.radarr))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.pushes == [TestKit.radarr])
    }

    @Test func everyEventReportsItsInstanceAlive() async throws {
        let kit = try await TestKit()
        let hub = EventHub(store: kit.store, clock: kit.clock)
        let recorder = PushRecorder()
        await hub.register(recorder)
        await hub.ingest(.queueStatus(TestKit.radarr, counts))
        await hub.ingest(.queueStatus(TestKit.radarr, counts))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.alive.count == 2)
    }

    @Test func aHiddenPanelStillActsOnAQueuePushBeforeAnyCountsArrived() async throws {
        let kit = try await TestKit()
        let hub = EventHub(store: kit.store, clock: kit.clock)
        let recorder = PushRecorder()
        await hub.register(recorder)
        await hub.setForeground(false)
        await hub.ingest(.queueChanged(TestKit.radarr))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.pushes == [TestKit.radarr])
    }
}
