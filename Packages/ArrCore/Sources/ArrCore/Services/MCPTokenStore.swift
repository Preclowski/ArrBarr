import Foundation
import Security

/// Keychain-backed storage for the MCP server's bearer token. Device-only,
/// never synced. Thin wrapper over `SecretStore` so there is one Keychain code
/// path; kept as a named type because several call sites read it as a static.
public enum MCPTokenStore {
    /// Device-only, never synced. Mirror `ConfigStore`'s secret backend: an
    /// ad-hoc/OSS build's file Keychain prompts on every rebuild and may not
    /// persist the write, so only entitled App Store builds use the Keychain —
    /// everything else (incl. `swift test`) uses UserDefaults. Without this the
    /// MCP server could fail to read back its own bearer token after relaunch
    /// (auth then breaks on exactly the self-hosted builds most likely to run it).
    private static let store: SecretStore =
        ConfigStore.makeDefaultSecretStore(defaults: .standard)

    public static func read() -> String? {
        if let token = store.read(.mcpBearer) { return token }
        // Self-healing migration: tokens written by builds <= the SecretStore
        // refactor lived at a different keychain location. Move it once.
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

    /// Generate a URL-safe random token (base64url, no padding).
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
