import Testing
import Foundation
import Security
@testable import ArrCore

/// Can this process reach the data-protection Keychain at all? An unsigned or
/// ad-hoc-signed binary — which every `swift test` runner is — gets
/// `errSecMissingEntitlement` back for *any* data-protection item, with or
/// without an access group. `KeychainSecretStore` is deliberately
/// data-protection-only (it must never touch the legacy file Keychain, which
/// prompts for the login password on every rebuild), so its round-trip is
/// simply untestable here — and it is never handed out in that environment
/// either, because `ConfigStore.makeDefaultSecretStore` falls back to
/// UserDefaults.
///
/// Measured directly instead of read off `AppCapabilities` so a probe override
/// left set by a concurrently running suite cannot flip the gate.
private let dataProtectionKeychainReachable: Bool = {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KeychainSecretStore.service,
        kSecAttrAccount as String: "secret.__reachability_probe__",
        kSecUseDataProtectionKeychain as String: true,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
    ]
    SecItemDelete(q as CFDictionary)
    var add = q
    add[kSecValueData as String] = Data("1".utf8)
    let status = SecItemAdd(add as CFDictionary, nil)
    SecItemDelete(q as CFDictionary)
    return status == errSecSuccess
}()

@Suite("SecretStore", .serialized)
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

    /// iCloud Keychain sync is the one thing still tied to the build flavor —
    /// it rides on entitlements only the App Store build carries. Where the item
    /// physically lives is not: see `AppCapabilitiesSuite` for the access group.
    @Test("baseQuery: synchronizable follows isAppStore, data protection does not")
    func keychainGatingRuntime() {
        let originalAppStore = AppCapabilities.isAppStore
        let originalProvider = KeychainSecretStore.syncEnabledProvider
        defer {
            AppCapabilities.configure(isAppStore: originalAppStore)
            KeychainSecretStore.syncEnabledProvider = originalProvider
        }
        KeychainSecretStore.syncEnabledProvider = { true }

        AppCapabilities.configure(isAppStore: true)
        let on = KeychainSecretStore.baseQuery(for: .openAIKey)
        #expect(on[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(KeychainSecretStore.baseQuery(for: .mcpBearer)[kSecAttrSynchronizable as String] as? Bool == false)

        AppCapabilities.configure(isAppStore: false)
        let off = KeychainSecretStore.baseQuery(for: .openAIKey)
        #expect(off[kSecAttrSynchronizable as String] as? Bool == false)

        // The attribute that must NOT track the flavor. Dropping it in any build
        // would route that build's writes to the legacy file Keychain, whose ACL
        // is pinned to the code signature — an ad-hoc build would then ask for
        // the login password on every single rebuild.
        #expect(on[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(off[kSecUseDataProtectionKeychain as String] as? Bool == true)
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

    @Test("synchronizable also honors the runtime sync provider when isAppStore")
    func keychainSynchronizableRespectsProvider() {
        let originalAppStore = AppCapabilities.isAppStore
        let originalProvider = KeychainSecretStore.syncEnabledProvider
        defer {
            AppCapabilities.configure(isAppStore: originalAppStore)
            KeychainSecretStore.syncEnabledProvider = originalProvider
        }
        AppCapabilities.configure(isAppStore: true)
        KeychainSecretStore.syncEnabledProvider = { false }
        #expect(KeychainSecretStore.baseQuery(for: .openAIKey)[kSecAttrSynchronizable as String] as? Bool == false)
        KeychainSecretStore.syncEnabledProvider = { true }
        #expect(KeychainSecretStore.baseQuery(for: .openAIKey)[kSecAttrSynchronizable as String] as? Bool == true)
    }

    @Test("Real Keychain round-trips a non-conflicting key",
          .enabled(if: dataProtectionKeychainReachable,
                   "unentitled binary: the data-protection Keychain rejects every call"))
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

    @Test("defaultSyncEnabled reads the device-local flag, defaulting true")
    func defaultSyncEnabledReadsFlag() {
        let suite = "test.icloudflag.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(KeychainSecretStore.syncEnabled(in: d) == true)   // unset → true
        d.set(false, forKey: KeychainSecretStore.iCloudSyncEnabledKey)
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
