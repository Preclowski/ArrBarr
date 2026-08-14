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

    /// Both intervals stopped being preferences: the queue is pushed at by
    /// SignalR, the bars interpolate between fetches, and the background poll
    /// only runs once realtime has gone silent. Pinned here so re-exposing
    /// them has to be a deliberate edit — the old test asserted the opposite.
    @Test("Refresh intervals are hard-locked, not stored")
    @MainActor func intervalsAreConstants() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let store = ConfigStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(store.foregroundInterval == 30)
        #expect(store.backgroundInterval == 30)
        // Nothing is written for them, so nothing can be restored either.
        #expect(defaults.object(forKey: "ArrBarr.foregroundInterval") == nil)
        #expect(defaults.object(forKey: "ArrBarr.backgroundInterval") == nil)
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

    // MARK: - migrateSecretsToKeychain tests

    /// A SecretStore whose writes silently fail (simulating a Keychain write with
    /// no entitlement), to prove migration never blanks UserDefaults unverified.
    final class FailingSecretStore: SecretStore, @unchecked Sendable {
        func read(_ key: SecretKey) -> String? { nil }   // read-back never verifies
        func set(_ value: String, for key: SecretKey) {}  // write is a no-op
        func delete(_ key: SecretKey) {}
    }

    @Test("migration leaves UserDefaults secrets intact when the Keychain write fails")
    @MainActor func migrationVerifiesBeforeBlanking() throws {
        let suite = "test.cfg.migrate.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        var cfg = ServiceConfig.empty
        cfg.apiKey = "secret-key"
        let data = try JSONEncoder().encode(cfg)
        d.set(data, forKey: ConfigStore.serviceKeyForTesting(.radarr))

        ConfigStore.migrateSecretsToKeychain(defaults: d, secrets: FailingSecretStore())

        let after = try JSONDecoder().decode(ServiceConfig.self,
                    from: d.data(forKey: ConfigStore.serviceKeyForTesting(.radarr))!)
        #expect(after.apiKey == "secret-key")
        #expect(d.bool(forKey: ConfigStore.secretsMigratedKeyForTesting) == false)
    }

    @Test("migration blanks UserDefaults and sets the done flag when writes verify")
    @MainActor func migrationSucceedsWithWorkingStore() throws {
        let suite = "test.cfg.migrate.ok.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        var cfg = ServiceConfig.empty
        cfg.apiKey = "k1"; cfg.password = "p1"
        d.set(try JSONEncoder().encode(cfg), forKey: ConfigStore.serviceKeyForTesting(.sonarr))

        let store = InMemorySecretStore()
        ConfigStore.migrateSecretsToKeychain(defaults: d, secrets: store)

        let after = try JSONDecoder().decode(ServiceConfig.self,
                    from: d.data(forKey: ConfigStore.serviceKeyForTesting(.sonarr))!)
        #expect(after.apiKey == "")
        #expect(after.password == "")
        #expect(store.read(.apiKey(for: .sonarr)) == "k1")
        #expect(store.read(.password(for: .sonarr)) == "p1")
        #expect(d.bool(forKey: ConfigStore.secretsMigratedKeyForTesting) == true)
    }

    @Test("ConfigStore and KeychainSecretStore agree on the iCloud flag key")
    func iCloudFlagKeyConstantsMatch() {
        #expect(ConfigStore.iCloudSyncEnabledKey == KeychainSecretStore.iCloudSyncEnabledKey)
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
