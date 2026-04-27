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

    @Test("Service config round-trips through persistence")
    @MainActor func saveAndLoad() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let config = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "test-api-key", username: "", password: ""
        )

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.update(.radarr, with: config)

        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.radarr == config)
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

        let store = ConfigStore(defaults: defaults, secrets: InMemorySecretStore())
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

        let store = ConfigStore(defaults: defaults, secrets: InMemorySecretStore())
        let config = ServiceConfig(
            enabled: true, baseURL: "http://test",
            apiKey: "key", username: "user", password: "pass"
        )

        for kind in ServiceKind.allCases {
            store.update(kind, with: config)
            #expect(store.config(for: kind) == config)
        }
    }

    @Test("Secrets persist in SecretStore, not UserDefaults")
    @MainActor func secretsInKeychain() throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let config = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "secret-key", username: "u", password: "secret-pw"
        )
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        store.update(.qbittorrent, with: config)

        // Defaults blob should not contain the secrets
        let blob = defaults.data(forKey: "ArrBarr.config.qbittorrent") ?? Data()
        let stripped = try JSONDecoder().decode(ServiceConfig.self, from: blob)
        #expect(stripped.apiKey == "")
        #expect(stripped.password == "")
        #expect(stripped.baseURL == "http://localhost:7878")

        // SecretStore holds them
        #expect(secrets.read(account: "qbittorrent.apiKey") == "secret-key")
        #expect(secrets.read(account: "qbittorrent.password") == "secret-pw")

        // Reload merges them back
        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.qbittorrent == config)
    }

    @Test("Legacy plaintext secrets migrate to SecretStore on load")
    @MainActor func legacyMigration() throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let legacy = ServiceConfig(
            enabled: true, baseURL: "http://localhost:7878",
            apiKey: "legacy-key", username: "", password: "legacy-pw"
        )
        let blob = try JSONEncoder().encode(legacy)
        defaults.set(blob, forKey: "ArrBarr.config.radarr")

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)

        // Effective config still complete
        #expect(store.radarr == legacy)
        // Secrets migrated to keychain
        #expect(secrets.read(account: "radarr.apiKey") == "legacy-key")
        #expect(secrets.read(account: "radarr.password") == "legacy-pw")
        // Defaults blob is now stripped
        let after = defaults.data(forKey: "ArrBarr.config.radarr") ?? Data()
        let stripped = try JSONDecoder().decode(ServiceConfig.self, from: after)
        #expect(stripped.apiKey == "")
        #expect(stripped.password == "")
    }

    @Test("Notification settings default to false and persist")
    @MainActor func notificationSettings() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let secrets = InMemorySecretStore()
        let store = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(store.notifyRadarr == false)
        #expect(store.notifySonarr == false)
        #expect(store.notifyLidarr == false)

        store.notifyRadarr = true
        store.notifySonarr = true

        let reloaded = ConfigStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.notifyRadarr == true)
        #expect(reloaded.notifySonarr == true)
        #expect(reloaded.notifyLidarr == false)
    }
}
