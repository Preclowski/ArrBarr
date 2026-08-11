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

    /// `removePersistentDomain` empties the domain but cfprefsd still persists
    /// an EMPTY plist to ~/Library/Preferences — one junk file per throwaway
    /// suite, forever (they piled up by the thousands). Remove the domain AND
    /// its backing file; the disk write can race us, so each test run also
    /// sweeps leftovers from earlier runs, keeping the count at ~zero.
    private func destroySuite(named name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        Self.deletePlist(named: name)
        Self.sweepStalePlists()
    }

    private static let preferencesDir = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")

    private static func deletePlist(named name: String) {
        try? FileManager.default.removeItem(
            at: preferencesDir.appendingPathComponent("\(name).plist"))
    }

    /// Only files older than 5 minutes: tests run in parallel, so a blanket
    /// sweep could delete a sibling test's LIVE suite mid-run. Anything a race
    /// leaves behind is seconds old now and gets collected on the next run.
    private static func sweepStalePlists() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: preferencesDir.path) else { return }
        for file in names where file.hasPrefix("ArrBarrDemoTests.") && file.hasSuffix(".plist") {
            let url = preferencesDir.appendingPathComponent(file)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            guard let modified, Date().timeIntervalSince(modified) > 300 else { continue }
            try? fm.removeItem(at: url)
        }
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
        defer { destroySuite(named: name) }

        let store = ConfigStore(defaults: suite, secrets: InMemorySecretStore())
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
        defer { destroySuite(named: name) }

        let store = ConfigStore(defaults: suite, secrets: InMemorySecretStore())
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
            destroySuite(named: realName)
            destroySuite(named: demoName)
        }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: real, secrets: secrets)
        store.useStore(demo)                      // switch to "demo" backing store
        store.whisparr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")

        // The write landed in demo, NOT in real.
        let realReload = ConfigStore(defaults: real, secrets: InMemorySecretStore())
        let demoReload = ConfigStore(defaults: demo, secrets: secrets)
        #expect(realReload.whisparr.enabled == false)
        #expect(demoReload.whisparr.enabled == true)
    }

    @Test("useStore round-trips between two stores without cross-contamination")
    @MainActor func useStoreRoundTrips() {
        let (a, an) = makeSuite()
        let (b, bn) = makeSuite()
        defer {
            destroySuite(named: an)
            destroySuite(named: bn)
        }
        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: a, secrets: secrets)
        store.radarr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")
        store.useStore(b)
        store.sonarr = ServiceConfig(enabled: true, baseURL: "", apiKey: "", username: "", password: "")
        store.useStore(a)
        // Back on `a`: radarr is the value we wrote to a; sonarr (written to b) is NOT here.
        #expect(store.radarr.enabled == true)
        #expect(store.sonarr.enabled == false)
        let bReload = ConfigStore(defaults: b, secrets: secrets)
        #expect(bReload.sonarr.enabled == true)
        #expect(bReload.radarr.enabled == false)
    }
}
