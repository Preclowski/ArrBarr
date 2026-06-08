import Testing
import Foundation
@testable import ArrCore

/// In-memory stand-in for NSUbiquitousKeyValueStore.
final class FakeKVStore: KeyValueSyncing, @unchecked Sendable {
    var storage: [String: Any] = [:]
    var synchronizeCalled = false
    var setCount = 0
    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ value: Any?, forKey key: String) { setCount += 1; storage[key] = value }
    @discardableResult func synchronize() -> Bool { synchronizeCalled = true; return true }
}

@Suite("KVSyncCoordinator")
struct KVSyncCoordinatorSuite {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "test.kvsync.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Outbound: pushing copies only allowlisted keys to KVS")
    @MainActor func outboundAllowlist() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(["needsyou", "radarr"], forKey: "ArrBarr.arrOrder")
        defaults.set(5.0, forKey: "ArrBarr.foregroundInterval")

        let kv = FakeKVStore()
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})
        coord.pushAllToKV()

        #expect(kv.object(forKey: "ArrBarr.arrOrder") != nil)
        #expect(kv.object(forKey: "ArrBarr.foregroundInterval") == nil)
    }

    @Test("Inbound: applying writes allowlisted KVS keys into defaults and reloads")
    @MainActor func inboundApplies() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        kv.storage["ArrBarr.showTonight"] = false
        kv.storage["ArrBarr.fontScale"] = 2.0

        var reloadCount = 0
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: { reloadCount += 1 })
        coord.applyFromKV(keys: ["ArrBarr.showTonight", "ArrBarr.fontScale"])

        #expect(defaults.object(forKey: "ArrBarr.showTonight") as? Bool == false)
        #expect(defaults.object(forKey: "ArrBarr.fontScale") == nil)
        #expect(reloadCount == 1)
    }

    @Test("Loop guard: a local push does not re-enter on the inbound path")
    @MainActor func loopGuard() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        var reloadCount = 0
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: { reloadCount += 1 })

        defaults.set(true, forKey: "ArrBarr.showNeedsYou")
        coord.observeDefault("ArrBarr.showNeedsYou")
        coord.applyFromKV(keys: ["ArrBarr.showNeedsYou"])
        #expect(reloadCount == 1)
    }

    @Test("start(): inbound apply does not trigger a reentrant outbound push storm")
    @MainActor func startLoopGuard() async {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        kv.storage["ArrBarr.showTonight"] = false
        var reloadCount = 0
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: { reloadCount += 1 })
        coord.start()
        let setsAfterStart = kv.setCount
        // Simulate an inbound iCloud change applied directly (as the block would):
        coord.applyFromKV(keys: ["ArrBarr.showTonight"])
        // Allow any queued main-queue notification blocks to drain.
        await Task.yield()
        #expect(defaults.object(forKey: "ArrBarr.showTonight") as? Bool == false)
        // The apply itself must not have caused a flood of extra KVS writes beyond
        // the allowlist push (i.e. no unbounded reentrant cascade).
        #expect(kv.setCount - setsAfterStart <= SyncedKeys.all.count)
        #expect(reloadCount >= 1)
    }
}
