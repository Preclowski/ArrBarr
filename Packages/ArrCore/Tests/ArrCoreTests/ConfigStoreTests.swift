import Testing
import Foundation
@testable import ArrCore

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

        let store = ConfigStore(defaults: defaults, secrets: InMemorySecretStore())
        for kind in ServiceKind.allCases {
            #expect(store.config(for: kind) == .empty)
        }
    }

    @Test("Default polling intervals are 5s foreground, 30s background")
    @MainActor func defaultIntervals() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(store.foregroundInterval == 5)
        #expect(store.backgroundInterval == 30)
    }

    @Test("Service config round-trips through persistence (including secrets)")
    @MainActor func saveAndLoad() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let config = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "test-api-key", username: "u", password: "test-password"
        )

        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.update(.radarr, with: config)

        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.radarr == config)
    }

    @Test("Secrets are not persisted as plaintext in UserDefaults")
    @MainActor func secretsNotInDefaults() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.update(.radarr, with: ServiceConfig(
            enabled: true, baseURL: "http://h:7878",
            apiKey: "SENSITIVE-KEY", username: "u", password: "SENSITIVE-PW"))

        let blob = defaults.data(forKey: "ArrBarr.config.radarr")!
        let raw = String(data: blob, encoding: .utf8)!
        #expect(!raw.contains("SENSITIVE-KEY"))
        #expect(!raw.contains("SENSITIVE-PW"))
        #expect(secrets.read(.apiKey(for: .radarr)) == "SENSITIVE-KEY")
        #expect(secrets.read(.password(for: .radarr)) == "SENSITIVE-PW")
    }

    @Test("Custom intervals persist")
    @MainActor func persistIntervals() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.foregroundInterval = 15
        store.backgroundInterval = 120

        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.foregroundInterval == 15)
        #expect(reloaded.backgroundInterval == 120)
    }

    @Test("config(for:) returns the correct service")
    @MainActor func configForKind() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
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

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        let config = ServiceConfig(
            enabled: true, baseURL: "http://test",
            apiKey: "key", username: "user", password: "pass"
        )

        for kind in ServiceKind.allCases {
            store.update(kind, with: config)
            #expect(store.config(for: kind) == config)
        }
    }

    @Test("Notification settings default to true and persist")
    @MainActor func notificationSettings() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(store.notifyRadarr == true)
        #expect(store.notifySonarr == true)
        #expect(store.notifyLidarr == true)

        store.notifyRadarr = false
        store.notifySonarr = false

        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.notifyRadarr == false)
        #expect(reloaded.notifySonarr == false)
        #expect(reloaded.notifyLidarr == true)
    }

    @Test("iCloudSyncEnabled defaults to true and persists")
    @MainActor func iCloudSyncEnabledPersists() {
        let suite = "test.cfg.icloud.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = ConfigStore(defaults: d, secrets: InMemorySecretStore())
        #expect(store.iCloudSyncEnabled == true)

        store.iCloudSyncEnabled = false
        #expect(d.bool(forKey: "ArrBarr.iCloudSyncEnabled") == false)

        let reloaded = ConfigStore(defaults: d, secrets: InMemorySecretStore())
        #expect(reloaded.iCloudSyncEnabled == false)
    }

}
