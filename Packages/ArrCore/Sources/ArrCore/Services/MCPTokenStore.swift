import CryptoKit
import Foundation

/// The MCP server's bearer token over `SecretStore`. Device-only, never synced.
nonisolated public enum MCPTokenStore {
    /// Same backend selection as `ConfigStore`, or the server couldn't read back
    /// its own token after a relaunch.
    private static let store: SecretStore =
        ConfigStore.makeDefaultSecretStore(defaults: .standard)

    public static func read() -> String? {
        if let token = store.read(.mcpBearer) { return token }
        // Tokens from before the SecretStore refactor lived in the file keychain, which can prompt for the login
        // password; look there once per install, not on every read of a missing token.
        guard !UserDefaults.standard.bool(forKey: legacyCheckedKey) else { return nil }
        UserDefaults.standard.set(true, forKey: legacyCheckedKey)
        guard let legacy = readLegacy() else { return nil }
        store.set(legacy, for: .mcpBearer)
        deleteLegacy()
        return legacy
    }

    public static func set(_ token: String) { store.set(token, for: .mcpBearer) }
    public static func delete() {
        store.delete(.mcpBearer)
        deleteLegacy()
    }

    public static func generate() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Legacy location (service "com.preclowski.ArrBarr.mcp", account "bearer")

    private static let legacyService = "com.preclowski.ArrBarr.mcp"
    private static let legacyAccount = "bearer"
    private static let legacyCheckedKey = "ArrBarr.mcpLegacyTokenChecked"

    private static func readLegacy() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacy() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
