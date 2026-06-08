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

    @Test("Real Keychain round-trips the MCP token")
    func keychainRoundTrips() {
        let store = KeychainSecretStore()
        let key = SecretKey.mcpBearer
        store.set("kc-token", for: key)
        #expect(store.read(key) == "kc-token")
        store.delete(key)
        #expect(store.read(key) == nil)
    }
}
