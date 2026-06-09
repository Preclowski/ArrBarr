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

    @Test("start(): inbound apply does not echo back to KVS (loop guard covers the async observer)")
    @MainActor func startLoopGuardNoEcho() async {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        kv.storage["ArrBarr.showTonight"] = false
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})
        coord.start()
        await Task.yield()                  // let start()'s initial observers/blocks settle
        let baseline = kv.setCount
        // Inbound change arrives and is applied:
        coord.applyFromKV(keys: ["ArrBarr.showTonight"])
        // Drain the main queue so any queued outbound observer block runs:
        await Task.yield()
        await Task.yield()
        // The inbound apply must not have triggered an outbound push of the
        // allowlist (the loop guard suppressed the didChange observer).
        #expect(kv.setCount == baseline)
        #expect(defaults.object(forKey: "ArrBarr.showTonight") as? Bool == false)
    }

    @Test("setEnabled(true) marks running and stamps lastSyncDate")
    @MainActor func setEnabledStarts() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})

        #expect(coord.isRunning == false)
        #expect(coord.lastSyncDate == nil)
        coord.setEnabled(true)
        #expect(coord.isRunning == true)
        #expect(coord.lastSyncDate != nil)
    }

    @Test("setEnabled(false) stops outbound pushes")
    @MainActor func setEnabledStops() async {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let kv = FakeKVStore()
        let coord = KVSyncCoordinator(defaults: defaults, kv: kv, reload: {})
        coord.setEnabled(true)
        await Task.yield()
        coord.setEnabled(false)
        #expect(coord.isRunning == false)
        let baseline = kv.setCount

        defaults.set(["radarr"], forKey: "ArrBarr.arrOrder")
        await Task.yield(); await Task.yield()
        #expect(kv.setCount == baseline)
    }

    @Test("accountAvailable updates live when the iCloud identity changes")
    @MainActor func accountAvailabilityReactsToIdentityChange() async {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        // A Sendable box the injected identity check reads, so we can flip the
        // simulated sign-in state from the test without a real iCloud account.
        final class Box: @unchecked Sendable { var signedIn = false }
        let box = Box()
        let coord = KVSyncCoordinator(defaults: defaults, kv: FakeKVStore(),
                                      reload: {}, identityCheck: { box.signedIn })
        #expect(coord.accountAvailable == false)

        box.signedIn = true
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        await Task.yield(); await Task.yield()   // let the main-queue observer run
        #expect(coord.accountAvailable == true)

        box.signedIn = false
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        await Task.yield(); await Task.yield()
        #expect(coord.accountAvailable == false)
    }

    @Test("setEnabled is idempotent — repeated enables are no-ops")
    @MainActor func setEnabledIdempotent() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let coord = KVSyncCoordinator(defaults: defaults, kv: FakeKVStore(), reload: {})
        coord.setEnabled(true)
        coord.setEnabled(true)
        #expect(coord.isRunning == true)
    }
}
