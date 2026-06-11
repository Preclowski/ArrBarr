import Testing
import Foundation
@testable import ArrCore

@Suite("Widget demo data path")
struct WidgetDemoPathTests {
    @Test("Demo flag round-trips through the group suite mirror")
    func mirror() {
        WidgetDataStore.setDemoActive(true)
        #expect(WidgetDataStore.isDemoActive == true)
        WidgetDataStore.setDemoActive(false)
        #expect(WidgetDataStore.isDemoActive == false)
    }

    @Test("Demo library summaries cover all four sources with non-zero data")
    func summaries() {
        let s = DemoMocks.librarySummaries()
        #expect(Set(s.map(\.source)) == Set(LibrarySummary.Source.allCases))
        #expect(s.allSatisfy { $0.count > 0 && $0.totalBytes > 0 })
    }
}

@Suite("Widget data store config read")
struct WidgetDataStoreReadTests {
    private func freshSuite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Reads a ServiceConfig written under the ArrBarr.config.<kind> key")
    func reads() throws {
        let suite = freshSuite("test.widgetstore.read")
        let cfg = ServiceConfig(enabled: true, baseURL: "https://radarr.local", apiKey: "k", username: "", password: "")
        let data = try JSONEncoder().encode(cfg)
        suite.set(data, forKey: "ArrBarr.config.radarr")

        let read = ConfigStore.decodeServiceConfig(.radarr, from: suite)
        #expect(read.baseURL == "https://radarr.local")
        #expect(read.apiKey == "k")
    }

    @Test("Missing key yields an empty (unconfigured) config")
    func missing() {
        let suite = freshSuite("test.widgetstore.missing")
        let read = ConfigStore.decodeServiceConfig(.sonarr, from: suite)
        #expect(read.isConfigured == false)
    }
}

@Suite("App Group migration")
struct AppGroupMigrationTests {
    private func fresh(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Copies all ArrBarr.* keys from source to group, sets done flag")
    func copies() throws {
        let src = fresh("test.mig.src")
        let grp = fresh("test.mig.grp")
        let cfg = try JSONEncoder().encode(ServiceConfig(enabled: true, baseURL: "https://r", apiKey: "k", username: "", password: ""))
        src.set(cfg, forKey: "ArrBarr.config.radarr")
        src.set(true, forKey: "ArrBarr.notifyRadarr")
        src.set("not-arrbarr", forKey: "SomeOtherApp.flag")

        ConfigStore.migrateToGroupSuite(from: src, to: grp)

        #expect(grp.data(forKey: "ArrBarr.config.radarr") == cfg)
        #expect(grp.bool(forKey: "ArrBarr.notifyRadarr") == true)
        #expect(grp.object(forKey: "SomeOtherApp.flag") == nil)
        #expect(grp.bool(forKey: ConfigStore.groupMigrationDoneKeyForTesting) == true)
    }

    @Test("Idempotent: a second run does not overwrite group edits")
    func idempotent() throws {
        let src = fresh("test.mig.src2")
        let grp = fresh("test.mig.grp2")
        src.set(1, forKey: "ArrBarr.foregroundInterval")
        ConfigStore.migrateToGroupSuite(from: src, to: grp)
        grp.set(99, forKey: "ArrBarr.foregroundInterval")
        ConfigStore.migrateToGroupSuite(from: src, to: grp)
        #expect(grp.integer(forKey: "ArrBarr.foregroundInterval") == 99)
    }

    @Test("Never reads or writes a third-party suite (demo-suite analogue)")
    func demoUntouched() throws {
        // Use a uniquely-named suite to stand in for the demo suite so this
        // test does not race with DemoIsolationTests (which also wipes the real
        // "pl.incred.ArrBarr.demo" suite). The invariant being tested is
        // that migrateToGroupSuite only ever touches `src` and `grp` — not any
        // other suite — which is equally proved with any third suite name.
        let src = fresh("test.mig.src3")
        let grp = fresh("test.mig.grp3")
        let thirdParty = fresh("test.mig.demo3")
        thirdParty.set("DEMO", forKey: "ArrBarr.config.radarr")
        src.set(Data("REAL".utf8), forKey: "ArrBarr.config.radarr")
        ConfigStore.migrateToGroupSuite(from: src, to: grp)
        #expect(thirdParty.string(forKey: "ArrBarr.config.radarr") == "DEMO")
        #expect(grp.data(forKey: "ArrBarr.config.radarr") == Data("REAL".utf8))
    }
}
