import Testing
import Foundation
@testable import ArrCore

/// Health is polled on a slow clock and a broken indexer stays broken, so the
/// same records come back every cycle. The whole value of the tracker is that
/// the second sighting is silent — an app that re-announces a standing problem
/// every fifteen minutes teaches its user to mute it.
@Suite("Health notification tracker")
struct HealthNotificationTrackerTests {
    private func record(_ type: String, _ message: String) -> ArrHealthRecord {
        ArrHealthRecord(source: nil, type: type, message: message, wikiUrl: nil)
    }

    @Test("A new problem is announced once, then stays quiet")
    func announcesOnce() {
        var tracker = HealthNotificationTracker()
        let broken = record("error", "Indexer unavailable")

        #expect(tracker.newIssues(for: .sonarr, records: [broken]).count == 1)
        #expect(tracker.newIssues(for: .sonarr, records: [broken]).isEmpty)
        #expect(tracker.newIssues(for: .sonarr, records: [broken]).isEmpty)
    }

    /// Two failures of the same *kind* are different problems. Servarr reuses a
    /// `type` across unrelated causes, so keying on it alone would announce the
    /// first broken indexer and silently swallow the second.
    @Test("Two problems sharing a type are announced separately")
    func distinguishesByMessage() {
        var tracker = HealthNotificationTracker()
        let first = record("error", "Indexer A unavailable")
        let second = record("error", "Indexer B unavailable")

        #expect(tracker.newIssues(for: .sonarr, records: [first]).count == 1)
        let next = tracker.newIssues(for: .sonarr, records: [first, second])
        #expect(next.map(\.message) == ["Indexer B unavailable"])
    }

    /// Resolution has to be remembered too, or a problem that comes back is
    /// never mentioned again — which is the failure the tracker exists to avoid,
    /// just delayed.
    @Test("A problem that clears and returns is announced again")
    func reannouncesAfterResolution() {
        var tracker = HealthNotificationTracker()
        let broken = record("error", "Download client unavailable")

        #expect(tracker.newIssues(for: .sonarr, records: [broken]).count == 1)
        #expect(tracker.newIssues(for: .sonarr, records: []).isEmpty)   // fixed
        #expect(tracker.newIssues(for: .sonarr, records: [broken]).count == 1)
    }

    @Test("Sources are tracked independently")
    func perSource() {
        var tracker = HealthNotificationTracker()
        let broken = record("error", "Indexer unavailable")

        #expect(tracker.newIssues(for: .sonarr, records: [broken]).count == 1)
        // Same message, different arr — a separate problem to report.
        #expect(tracker.newIssues(for: .radarr, records: [broken]).count == 1)
    }

    @Test("Survives a round-trip through its persisted form")
    func codableRoundTrip() throws {
        var tracker = HealthNotificationTracker()
        let broken = record("error", "Indexer unavailable")
        _ = tracker.newIssues(for: .sonarr, records: [broken])

        let data = try JSONEncoder().encode(tracker)
        var restored = try JSONDecoder().decode(HealthNotificationTracker.self, from: data)

        // The point of persisting: a relaunch must not re-announce it.
        #expect(restored.newIssues(for: .sonarr, records: [broken]).isEmpty)
    }
}
