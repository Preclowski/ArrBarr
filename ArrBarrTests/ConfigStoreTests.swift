import Testing
import Foundation
@testable import ArrBarr

@Suite("ConfigStore")
struct ConfigStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ArrBarrTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Fresh store returns empty configs")
    @MainActor func freshDefaults() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults)
        for kind in ServiceKind.allCases {
            #expect(store.config(for: kind) == .empty)
        }
    }

    @Test("Default polling intervals are 5s foreground, 30s background")
    @MainActor func defaultIntervals() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults)
        #expect(store.foregroundInterval == 5)
        #expect(store.backgroundInterval == 30)
    }

    @Test("Service config round-trips through persistence (including secrets)")
    @MainActor func saveAndLoad() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let config = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "test-api-key", username: "u", password: "test-password"
        )

        let store = ConfigStore(defaults: defaults)
        store.update(.radarr, with: config)

        let reloaded = ConfigStore(defaults: defaults)
        #expect(reloaded.radarr == config)
    }

    @Test("Custom intervals persist")
    @MainActor func persistIntervals() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults)
        store.foregroundInterval = 15
        store.backgroundInterval = 120

        let reloaded = ConfigStore(defaults: defaults)
        #expect(reloaded.foregroundInterval == 15)
        #expect(reloaded.backgroundInterval == 120)
    }

    @Test("config(for:) returns the correct service")
    @MainActor func configForKind() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults)
        let radarrConfig = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "radarr-key", username: "", password: ""
        )
        let sonarrConfig = ServiceConfig(
            enabled: true, baseURL: "http://localhost:8989",
            apiKey: "sonarr-key", username: "", password: ""
        )
        store.update(.radarr, with: radarrConfig)
        store.update(.sonarr, with: sonarrConfig)

        #expect(store.config(for: .radarr) == radarrConfig)
        #expect(store.config(for: .sonarr) == sonarrConfig)
        #expect(store.config(for: .radarr) != sonarrConfig)
    }

    @Test("update(:with:) sets all nine service kinds")
    @MainActor func updateAllKinds() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults)
        let config = ServiceConfig(
            enabled: true, baseURL: "http://test",
            apiKey: "key", username: "user", password: "pass"
        )

        for kind in ServiceKind.allCases {
            store.update(kind, with: config)
            #expect(store.config(for: kind) == config)
        }
    }

    @Test("Notification settings default to false and persist")
    @MainActor func notificationSettings() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults)
        #expect(store.notifyRadarr == false)
        #expect(store.notifySonarr == false)
        #expect(store.notifyLidarr == false)

        store.notifyRadarr = true
        store.notifySonarr = true

        let reloaded = ConfigStore(defaults: defaults)
        #expect(reloaded.notifyRadarr == true)
        #expect(reloaded.notifySonarr == true)
        #expect(reloaded.notifyLidarr == false)
    }

    @Test("Migration flag prevents repeated keychain probing")
    @MainActor func migrationFlagSetOnce() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        _ = ConfigStore(defaults: defaults)
        #expect(defaults.bool(forKey: "ArrBarr.keychainMigrationDone") == true)
    }
}
