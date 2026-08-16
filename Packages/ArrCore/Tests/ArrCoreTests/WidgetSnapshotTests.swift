import Foundation
import Testing
@testable import ArrCore

/// A snapshot write used to happen inline, on the main-actor refresh path, into
/// an App Group container resolved through a system daemon. When that daemon
/// stalled, `QueueViewModel.refresh()` sat in `Data.write` at 0% CPU — a whole
/// test run hung there for 15+ minutes, and in the app the same call freezes the
/// UI. The write is now asynchronous and, under a test bundle, local.
@Suite("Upcoming snapshot", .serialized)
struct WidgetSnapshotTests {

    private func withTempSnapshotDir(_ body: (URL) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WidgetDataStore.snapshotDirectoryOverrideForTesting = dir
        defer {
            WidgetDataStore.snapshotDirectoryOverrideForTesting = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(dir)
    }

    /// Polls rather than sleeping a fixed interval — the write is on a queue,
    /// and the point of the test is that the caller didn't wait for it.
    private func waitForFile(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("The snapshot round-trips through the file")
    func snapshotRoundTrips() async throws {
        try await withTempSnapshotDir { dir in
            let items = [
                UpcomingItem(id: "s1", source: .sonarr, title: "Severance", subtitle: "S02E01",
                             airDate: Date(timeIntervalSince1970: 1_700_000_000),
                             releaseType: nil, hasFile: false, overview: nil)
            ]
            WidgetDataStore.saveUpcoming(items)

            #expect(await waitForFile(dir.appendingPathComponent("upcoming-snapshot.json")))
            #expect(WidgetDataStore.loadUpcoming().first?.title == "Severance")
        }
    }

    /// The actual regression guard, and the reason for the DEBUG hook: the
    /// write is held hostage, so this can only pass if the caller isn't
    /// waiting for it. Asserting on a *failing* write instead would prove
    /// nothing — a failure returns fast even from the old inline code, while
    /// the bug was a write that never returned at all.
    @Test("A stalled write cannot reach the caller")
    func saveDoesNotBlockOnStalledWrite() async throws {
        try await withTempSnapshotDir { dir in
            let file = dir.appendingPathComponent("upcoming-snapshot.json")
            let release = DispatchSemaphore(value: 0)
            WidgetDataStore.blockSnapshotQueueForTesting(until: release)
            defer { release.signal() }

            let started = Date()
            WidgetDataStore.saveUpcoming([])
            let elapsed = Date().timeIntervalSince(started)

            // Generous on purpose — this asserts "didn't wait for I/O", not a
            // performance budget, and CI machines are slow.
            #expect(elapsed < 0.5)
            // The write really is still parked behind the semaphore…
            #expect(!FileManager.default.fileExists(atPath: file.path))
            // …and lands once it is released.
            release.signal()
            #expect(await waitForFile(file))
        }
    }

    /// A destination that refuses writes must stay a logged failure, not an
    /// error the refresh has to handle.
    @Test("An unwritable destination fails quietly")
    func unwritableDestinationIsContained() async throws {
        try await withTempSnapshotDir { dir in
            // Occupy the snapshot path with a directory: writes to it can't
            // succeed, and the fallback candidates are suppressed under test.
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("upcoming-snapshot.json"),
                withIntermediateDirectories: true)

            WidgetDataStore.saveUpcoming([])
            try await Task.sleep(for: .milliseconds(200))

            #expect(WidgetDataStore.loadUpcoming().isEmpty)
        }
    }

    /// Tests must not leave files in the user's real Library. Before the
    /// redirect, running this package wrote into
    /// `~/Library/Group Containers/group.pl.incred.ArrBarr` and
    /// `~/Library/Application Support` on the developer's own machine.
    @Test("A test process writes its snapshot somewhere temporary, not the user's Library")
    func testProcessStaysOutOfUserLibrary() async throws {
        WidgetDataStore.snapshotDirectoryOverrideForTesting = nil
        WidgetDataStore.saveUpcoming([])
        // Give the queued write time to land wherever it is going.
        try await Task.sleep(for: .milliseconds(200))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden = [
            "\(home)/Library/Group Containers/group.pl.incred.ArrBarr/upcoming-snapshot.json",
            "\(home)/Library/Application Support/upcoming-snapshot.json",
        ]
        for path in forbidden {
            let touchedNow = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
                .flatMap { $0 as? Date }
                .map { Date().timeIntervalSince($0) < 60 } ?? false
            #expect(!touchedNow, "test run wrote into the user's Library: \(path)")
        }
    }
}
