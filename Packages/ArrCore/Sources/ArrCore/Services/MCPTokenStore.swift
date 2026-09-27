import Foundation
import Security

/// The MCP server's bearer token over `SecretStore`. Device-only, never synced.
public enum MCPTokenStore {
    /// Same backend selection as `ConfigStore`, or the server couldn't read back
    /// its own token after a relaunch.
    private static let store: SecretStore =
        ConfigStore.makeDefaultSecretStore(defaults: .standard)

    public static func read() -> String? {
        if let token = store.read(.mcpBearer) { return token }
        // Tokens from before the SecretStore refactor lived at a different keychain location.
        if let legacy = readLegacy() {
            store.set(legacy, for: .mcpBearer)
            deleteLegacy()
            return legacy
        }
        return nil
    }

    public static func set(_ token: String) { store.set(token, for: .mcpBearer) }
    public static func delete() {
        store.delete(.mcpBearer)
        deleteLegacy()
    }

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Legacy location (service "com.preclowski.ArrBarr.mcp", account "bearer")

    private static let legacyService = "com.preclowski.ArrBarr.mcp"
    private static let legacyAccount = "bearer"

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
