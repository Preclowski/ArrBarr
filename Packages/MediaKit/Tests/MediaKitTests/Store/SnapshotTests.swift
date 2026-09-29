import Foundation
import Testing
@testable import MediaKit

@Suite struct SnapshotTests {
    @Test func aBurstOfInvalidationsRebuildsOnce() async throws {
        let kit = try await TestKit()
        let tag = InvalidationTag.collection(.library, TestKit.radarr)
        let builds = Counter()
        let snapshot = Snapshot(tags: [tag], initial: 0, store: kit.store, settle: .milliseconds(40)) { _ in
            builds.increment()
            return builds.value
        }
        await snapshot.start()
        #expect(builds.value == 1)
        // Back to back, so the burst sits inside one settle window however loaded the machine is.
        for _ in 0..<5 { await kit.store.invalidate([tag], reason: .manual) }
        try await eventually { builds.value == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(builds.value == 2)
        snapshot.stop()
    }

    @Test func aPurgeRebuilds() async throws {
        let kit = try await TestKit()
        let builds = Counter()
        let snapshot = Snapshot(tags: [.collection(.library, TestKit.radarr)], initial: 0, store: kit.store) { _ in
            builds.increment()
            return builds.value
        }
        await snapshot.start()
        await kit.store.purgeAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(builds.value == 2)
        snapshot.stop()
    }
}
