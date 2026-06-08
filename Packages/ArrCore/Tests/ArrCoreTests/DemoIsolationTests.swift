import Testing
import Foundation
@testable import ArrCore

@Suite("Demo isolation")
struct DemoIsolationTests {
    /// A throwaway suite standing in for `.standard` (the "real profile") plus
    /// a second standing in for the demo suite, so tests never touch the real
    /// user defaults.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "ArrBarrDemoTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("resetDemoStore wipes only the demo suite, never standard")
    func resetTargetsDemoSuiteOnly() {
        // Real profile sentinel lives in .standard under a unique key.
        let sentinelKey = "ArrBarrDemoTests.realSentinel.\(UUID().uuidString)"
        UserDefaults.standard.set("keep-me", forKey: sentinelKey)
        defer { UserDefaults.standard.removeObject(forKey: sentinelKey) }

        // Seed the demo suite, then reset it.
        let demo = DemoMode.demoDefaults!
        demo.set(true, forKey: DemoMode.seedDoneKey)
        DemoMode.resetDemoStore()
        defer { DemoMode.resetDemoStore() }

        #expect(DemoMode.demoDefaults!.bool(forKey: DemoMode.seedDoneKey) == false)
        #expect(UserDefaults.standard.string(forKey: sentinelKey) == "keep-me")
    }

    @Test("seedDemoConfigsIfNeeded enables radarr/sonarr/lidarr, leaves whisparr off")
    @MainActor func seedEnablesThreeArrs() {
        let (suite, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: suite)
        store.seedDemoConfigsIfNeeded()

        #expect(store.radarr.enabled == true)
        #expect(store.sonarr.enabled == true)
        #expect(store.lidarr.enabled == true)
        #expect(store.whisparr.enabled == false)
        #expect(suite.bool(forKey: DemoMode.seedDoneKey) == true)
    }

    @Test("seed runs once — after seedDone, re-seeding does not re-enable a user-disabled arr")
    @MainActor func seedRunsOnce() {
        let (suite, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: suite)
        store.seedDemoConfigsIfNeeded()          // first seed: all three on
        store.radarr.enabled = false             // user turns radarr off
        store.seedDemoConfigsIfNeeded()          // should be a no-op now

        #expect(store.radarr.enabled == false)
    }

    @Test("useStore re-points backing store so later writes isolate to the new suite")
    @MainActor func useStoreIsolatesWrites() {
        let (real, realName) = makeSuite()
        let (demo, demoName) = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: realName)
            UserDefaults.standard.removePersistentDomain(forName: demoName)
        }

        let store = ConfigStore(defaults: real)
        store.useStore(demo)                      // switch to "demo" backing store
        store.whisparr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")

        // The write landed in demo, NOT in real.
        let realReload = ConfigStore(defaults: real)
        let demoReload = ConfigStore(defaults: demo)
        #expect(realReload.whisparr.enabled == false)
        #expect(demoReload.whisparr.enabled == true)
    }

    @Test("useStore round-trips between two stores without cross-contamination")
    @MainActor func useStoreRoundTrips() {
        let (a, an) = makeSuite()
        let (b, bn) = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: an)
            UserDefaults.standard.removePersistentDomain(forName: bn)
        }
        let store = ConfigStore(defaults: a)
        store.radarr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")
        store.useStore(b)
        store.sonarr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")
        store.useStore(a)
        // Back on `a`: radarr is the value we wrote to a; sonarr (written to b) is NOT here.
        #expect(store.radarr.enabled == true)
        #expect(store.sonarr.enabled == false)
        let bReload = ConfigStore(defaults: b)
        #expect(bReload.sonarr.enabled == true)
        #expect(bReload.radarr.enabled == false)
    }
}
