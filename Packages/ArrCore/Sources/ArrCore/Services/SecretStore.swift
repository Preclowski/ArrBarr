import Foundation
import Security

/// A single secret (one Keychain generic-password account) plus the policy for
/// how it is stored: whether it should sync via iCloud Keychain (`synced`, only
/// honored in App Store builds) and whether it is pinned to this device
/// (`deviceOnly`).
public struct SecretKey: Sendable, Equatable {
    public let account: String
    /// Request iCloud Keychain sync. Only takes effect under `#if APPSTORE`;
    /// non-App-Store builds always store locally.
    public let synced: Bool
    /// `true` → `WhenUnlockedThisDeviceOnly`; `false` → `AfterFirstUnlock`
    /// (needed for background / widget reads on iOS).
    public let deviceOnly: Bool

    public static func apiKey(for kind: ServiceKind) -> SecretKey {
        SecretKey(account: "secret.\(kind.rawValue).apiKey", synced: true, deviceOnly: false)
    }
    public static func password(for kind: ServiceKind) -> SecretKey {
        SecretKey(account: "secret.\(kind.rawValue).password", synced: true, deviceOnly: false)
    }
    public static let openAIKey = SecretKey(account: "secret.openai.apiKey", synced: true, deviceOnly: false)
    public static let tmdbKey   = SecretKey(account: "secret.tmdb.apiKey", synced: true, deviceOnly: false)
    /// The MCP server bearer token gates a server bound to one machine, so it is
    /// never synced and stays device-only.
    public static let mcpBearer = SecretKey(account: "secret.mcp.bearer", synced: false, deviceOnly: true)
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) -> String?
    func set(_ value: String, for key: SecretKey)
    func delete(_ key: SecretKey)
}

/// Keychain-backed `SecretStore`. All items share the `service` namespace; the
/// `SecretKey.account` distinguishes them.
public struct KeychainSecretStore: SecretStore {
    static let service = "com.preclowski.ArrBarr"

    public init() {}

    /// The identifying query fields + storage policy for a key. Exposed so tests
    /// can assert the synchronizable/accessibility gating without touching the
    /// real Keychain.
    public static func baseQuery(for key: SecretKey) -> [String: Any] {
        #if APPSTORE
        let synchronizable = key.synced
        #else
        let synchronizable = false
        #endif
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: key.deviceOnly
                ? (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                : (kSecAttrAccessibleAfterFirstUnlock as String),
        ]
    }

    public func read(_ key: SecretKey) -> String? {
        var q = Self.baseQuery(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for key: SecretKey) {
        delete(key)
        var q = Self.baseQuery(for: key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    public func delete(_ key: SecretKey) {
        SecItemDelete(Self.baseQuery(for: key) as CFDictionary)
    }
}

/// In-memory `SecretStore` for tests — never touches the real Keychain.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }; return values[key.account]
    }
    public func set(_ value: String, for key: SecretKey) {
        lock.lock(); defer { lock.unlock() }; values[key.account] = value
    }
    public func delete(_ key: SecretKey) {
        lock.lock(); defer { lock.unlock() }; values[key.account] = nil
    }
}
