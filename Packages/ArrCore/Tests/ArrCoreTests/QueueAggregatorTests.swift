import Testing
import Foundation
@testable import ArrCore

@Suite("QueueAggregator.fetch")
@MainActor
struct QueueAggregatorTests {
    private func makeConfigStore() -> ConfigStore {
        let suiteName = "QueueAggregatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ConfigStore(defaults: defaults)
    }

    @Test("Unconfigured arrs do not surface a queue error")
    func unconfiguredArrsAreSilent() async {
        // Fresh store → every arr is unconfigured, so each client throws
        // `notConfigured` *before* any network call (no I/O in this test).
        // Those must NOT become user-visible queue errors — Upcoming/Health
        // already swallow them, and an unconfigured Lidarr/Whisparr showing
        // "Service not configured" in the queue is the bug.
        let aggregator = QueueAggregator(configStore: makeConfigStore())
        let result = await aggregator.fetch()
        #expect(result.radarrError == nil)
        #expect(result.sonarrError == nil)
        #expect(result.lidarrError == nil)
        #expect(result.whisparrError == nil)
    }
}
