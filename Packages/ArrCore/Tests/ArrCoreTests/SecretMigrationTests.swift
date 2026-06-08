import Testing
import Foundation
@testable import ArrCore

@Suite("SecretMigration")
struct SecretMigrationSuite {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "test.secretmig.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Plaintext secrets in defaults move to the secret store and are blanked")
    @MainActor func migratesAndBlanks() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let legacy = ServiceConfig(enabled: true, baseURL: "http://h:7878",
                                   apiKey: "LEGACY-KEY", username: "u", password: "LEGACY-PW")
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "ArrBarr.config.radarr")

        let secrets = InMemorySecretStore()
        ConfigStore.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)

        #expect(secrets.read(.apiKey(for: .radarr)) == "LEGACY-KEY")
        #expect(secrets.read(.password(for: .radarr)) == "LEGACY-PW")

        let blob = defaults.data(forKey: "ArrBarr.config.radarr")!
        let raw = String(data: blob, encoding: .utf8)!
        #expect(!raw.contains("LEGACY-KEY"))
        #expect(!raw.contains("LEGACY-PW"))
    }

    @Test("Migration is idempotent and a no-op on a secret-less store")
    @MainActor func idempotentNoOp() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let secrets = InMemorySecretStore()
        ConfigStore.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)
        ConfigStore.migrateSecretsToKeychain(defaults: defaults, secrets: secrets)
        #expect(secrets.read(.apiKey(for: .radarr)) == nil)
        #expect(defaults.bool(forKey: "ArrBarr.secretsMigratedToKeychain") == true)
    }
}
