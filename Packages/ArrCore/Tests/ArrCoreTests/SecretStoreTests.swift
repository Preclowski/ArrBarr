import Testing
import Foundation
@testable import ArrCore

@Suite("SecretStore")
struct SecretStoreSuite {

    @Test("InMemory fake round-trips and deletes")
    func inMemoryRoundTrips() {
        let store = InMemorySecretStore()
        let key = SecretKey.apiKey(for: .radarr)
        #expect(store.read(key) == nil)
        store.set("secret-123", for: key)
        #expect(store.read(key) == "secret-123")
        store.delete(key)
        #expect(store.read(key) == nil)
    }

    @Test("MCP bearer key is device-only and never synced")
    func mcpKeyIsDeviceOnly() {
        let key = SecretKey.mcpBearer
        #expect(key.deviceOnly == true)
        #expect(key.synced == false)
    }

    @Test("Service/openai/tmdb keys request sync and are not device-only")
    func syncedKeysFlags() {
        for key in [SecretKey.apiKey(for: .sonarr),
                    SecretKey.password(for: .qbittorrent),
                    SecretKey.openAIKey,
                    SecretKey.tmdbKey] {
            #expect(key.synced == true)
            #expect(key.deviceOnly == false)
        }
    }

    @Test("Keychain query honors synchronizable only under APPSTORE")
    func keychainSynchronizableGating() {
        let synced = KeychainSecretStore.baseQuery(for: .openAIKey)
        let mcp = KeychainSecretStore.baseQuery(for: .mcpBearer)
        #if APPSTORE
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == true)
        #else
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == false)
        #endif
        #expect(mcp[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("Keychain accessibility: MCP device-only, synced after-first-unlock")
    func keychainAccessibility() {
        let synced = KeychainSecretStore.baseQuery(for: .tmdbKey)
        let mcp = KeychainSecretStore.baseQuery(for: .mcpBearer)
        #expect(synced[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlock as String))
        #expect(mcp[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }

    @Test("Access group + data-protection keychain set only under APPSTORE")
    func keychainAccessGroupGating() {
        let q = KeychainSecretStore.baseQuery(for: .apiKey(for: .radarr))
        #if APPSTORE
        #expect(q[kSecAttrAccessGroup as String] as? String == KeychainSecretStore.accessGroup)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #else
        #expect(q[kSecAttrAccessGroup as String] == nil)
        #expect(q[kSecUseDataProtectionKeychain as String] == nil)
        #endif
    }

    @Test("Real Keychain round-trips a non-conflicting key")
    func keychainRoundTrips() {
        // Use a DEDICATED throwaway account — never a real SecretKey (.tmdbKey,
        // .apiKey(for:), …). A real key would collide with the user's actual
        // secrets in the developer's login Keychain, and an intermediate dev-time
        // run once polluted the real Keychain that way. Device-only + immediate
        // cleanup means nothing persists across runs.
        let store = KeychainSecretStore()
        let key = SecretKey(account: "secret.__roundtrip_test__", synced: false, deviceOnly: true)
        defer { store.delete(key) }
        store.set("kc-token", for: key)
        #expect(store.read(key) == "kc-token")
        store.delete(key)
        #expect(store.read(key) == nil)
    }

    @Test("syncable lists every per-service key plus openai/tmdb, excludes mcpBearer")
    func syncableContents() {
        let accounts = Set(SecretKey.syncable.map(\.account))
        for kind in ServiceKind.allCases {
            #expect(accounts.contains("secret.\(kind.rawValue).apiKey"))
            #expect(accounts.contains("secret.\(kind.rawValue).password"))
        }
        #expect(accounts.contains("secret.openai.apiKey"))
        #expect(accounts.contains("secret.tmdb.apiKey"))
        #expect(!accounts.contains("secret.mcp.bearer"))
        #expect(SecretKey.syncable.allSatisfy { $0.synced && !$0.deviceOnly })
    }

    @Test("baseQuery synchronizable honors the runtime sync provider (APPSTORE only)")
    func keychainSynchronizableRuntimeGating() {
        let original = KeychainSecretStore.syncEnabledProvider
        defer { KeychainSecretStore.syncEnabledProvider = original }

        KeychainSecretStore.syncEnabledProvider = { false }
        let off = KeychainSecretStore.baseQuery(for: .openAIKey)
        #expect(off[kSecAttrSynchronizable as String] as? Bool == false)

        KeychainSecretStore.syncEnabledProvider = { true }
        let on = KeychainSecretStore.baseQuery(for: .openAIKey)
        #if APPSTORE
        #expect(on[kSecAttrSynchronizable as String] as? Bool == true)
        #else
        #expect(on[kSecAttrSynchronizable as String] as? Bool == false)
        #endif
    }

    @Test("defaultSyncEnabled reads the device-local flag, defaulting true")
    func defaultSyncEnabledReadsFlag() {
        let suite = "test.icloudflag.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(KeychainSecretStore.syncEnabled(in: d) == true)   // unset → true
        d.set(false, forKey: "ArrBarr.iCloudSyncEnabled")
        #expect(KeychainSecretStore.syncEnabled(in: d) == false)
    }

    @Test("reapplySyncAttribute rewrites only keys that currently hold a value")
    func reapplyRewritesPresentOnly() {
        let store = RecordingSecretStore()
        let present = SecretKey.apiKey(for: .radarr)
        store.set("v", for: present)
        store.resetLog()

        store.reapplySyncAttribute(for: SecretKey.syncable)

        #expect(store.setLog == [present.account])
        #expect(store.read(present) == "v")
    }
}

/// SecretStore that records which accounts were re-written, to assert
/// `reapplySyncAttribute` only touches keys that hold a value.
fileprivate final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private(set) var setLog: [String] = []
    func read(_ key: SecretKey) -> String? { values[key.account] }
    func set(_ value: String, for key: SecretKey) {
        values[key.account] = value; setLog.append(key.account)
    }
    func delete(_ key: SecretKey) { values[key.account] = nil }
    func resetLog() { setLog.removeAll() }
}
