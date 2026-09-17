import Testing
import Foundation
@testable import ArrCore

/// `collapsedArrs` and `queueTitleGrouping` moved off `ConfigStore` so that
/// collapsing a queue section stops invalidating every view observing the
/// store. What must NOT change with them: the keys, the suite they are
/// written to, and the fact that a reload doesn't write anything back — all
/// three are load-bearing for iCloud sync (`SyncedKeys` + `KVSyncCoordinator`).
@Suite("Queue UI state")
@MainActor
struct QueueUIStateTests {

    /// The house pattern (see `ConfigStoreTests`): a suite nobody else can
    /// name, torn down in a `defer`. Wiping a FIXED domain up front — the first
    /// version of this file — flushes cfprefsd for the whole process and was
    /// enough to push the suite's timing-sensitive network tests over their
    /// timeouts when they ran alongside.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ArrBarrTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Writes land on the same keys ConfigStore used")
    func writesUseTheSharedKeys() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let state = QueueUIState(defaults: defaults)
        state.queueTitleGrouping = .expanded
        state.toggleCollapsed("radarr")

        #expect(defaults.string(forKey: "ArrBarr.queueTitleGrouping") == "expanded")
        #expect(defaults.stringArray(forKey: "ArrBarr.collapsedArrs") == ["radarr"])
    }

    @Test("A fresh instance reads what the previous one wrote")
    func roundTrips() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let first = QueueUIState(defaults: defaults)
        first.queueTitleGrouping = .off
        first.toggleCollapsed("sonarr")

        let second = QueueUIState(defaults: defaults)
        #expect(second.queueTitleGrouping == .off)
        #expect(second.isCollapsed("sonarr"))
    }

    @Test("An inbound iCloud change is picked up by a reload")
    func reloadPicksUpExternalWrites() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let state = QueueUIState(defaults: defaults)
        #expect(state.queueTitleGrouping == .collapsed)

        // What KVSyncCoordinator does: write into the suite, then ask for a reload.
        defaults.set("expanded", forKey: "ArrBarr.queueTitleGrouping")
        defaults.set(["lidarr"], forKey: "ArrBarr.collapsedArrs")
        state.reloadFromDefaults()

        #expect(state.queueTitleGrouping == .expanded)
        #expect(state.isCollapsed("lidarr"))
    }

    @Test("A reload writes nothing back")
    func reloadDoesNotPersist() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let state = QueueUIState(defaults: defaults)
        state.queueTitleGrouping = .expanded
        // Clear the keys behind its back, then reload: the values reset to
        // their defaults, and a setter that persisted during a load would put
        // them straight back — which through UserDefaults.didChangeNotification
        // is an iCloud push echoing a change that came from iCloud.
        defaults.removeObject(forKey: "ArrBarr.queueTitleGrouping")
        defaults.removeObject(forKey: "ArrBarr.collapsedArrs")
        state.reloadFromDefaults()

        #expect(state.queueTitleGrouping == .collapsed)
        #expect(defaults.object(forKey: "ArrBarr.queueTitleGrouping") == nil)
        #expect(defaults.object(forKey: "ArrBarr.collapsedArrs") == nil)
    }

    @Test("Both keys are still on the iCloud allow-list")
    func keysStaySynced() {
        #expect(SyncedKeys.all.contains("ArrBarr.queueTitleGrouping"))
        #expect(SyncedKeys.all.contains("ArrBarr.collapsedArrs"))
    }
}
