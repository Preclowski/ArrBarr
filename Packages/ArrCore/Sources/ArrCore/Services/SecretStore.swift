import Foundation
import Security
import os

/// A Keychain generic-password account plus its storage policy.
nonisolated public struct SecretKey: Sendable, Equatable {
    public let account: String
    /// iCloud Keychain sync; only honored under `#if APPSTORE`.
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
    public static let prowlarrKey = SecretKey(account: "secret.prowlarr.apiKey", synced: true, deviceOnly: false)
    /// Plex `X-Plex-Token` / Jellyfin / Emby API key.
    public static let mediaServerToken = SecretKey(account: "secret.mediaServer.token", synced: true, deviceOnly: false)
    /// Gates a server bound to one machine, so never synced.
    public static let mcpBearer = SecretKey(account: "secret.mcp.bearer", synced: false, deviceOnly: true)

    /// Every secret the app stores; the migration and sync loops all walk this one list.
    public static let all: [SecretKey] = ServiceKind.allCases.flatMap { [apiKey(for: $0), password(for: $0)] }
        + [openAIKey, tmdbKey, prowlarrKey, mediaServerToken, mcpBearer]

    public static let syncable: [SecretKey] = all.filter(\.synced)
}

nonisolated public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) -> String?
    func set(_ value: String, for key: SecretKey)
    func delete(_ key: SecretKey)
}

nonisolated public extension SecretStore {
    /// Rewrites each stored secret so the write path re-stamps a changed
    /// `synchronizable` attribute.
    func reapplySyncAttribute(for keys: [SecretKey]) {
        for key in keys {
            if let value = read(key) { set(value, for: key) }
        }
    }
}

nonisolated struct KeychainSecretStore: SecretStore {
    static let service = "pl.incred.ArrBarr"
    /// Team-prefixed group shared with the iOS widget. Only App Store signatures
    /// provision it; OSS/ad-hoc builds and forks fail the probe and use `UserDefaultsSecretStore`.
    static let accessGroup = "9M6DR2Z85Y.pl.incred.ArrBarr.shared"
    private static let logger = Logger(category: "SecretStore")

    /// Mirrors `ConfigStore.iCloudSyncEnabledKey`, duplicated so this nonisolated
    /// layer stays free of ConfigStore.
    static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"

    /// Overridable for tests.
    @TaskLocal static var syncEnabledProvider: @Sendable () -> Bool = {
        syncEnabled(in: WidgetDataStore.groupDefaults())
    }

    nonisolated static func syncEnabled(in defaults: UserDefaults?) -> Bool {
        guard let defaults, defaults.object(forKey: iCloudSyncEnabledKey) != nil
        else { return true }
        return defaults.bool(forKey: iCloudSyncEnabledKey)
    }

    init() {}

    /// `kSecUseDataProtectionKeychain` must stay unconditional: the legacy file Keychain's
    /// ACL is bound to the code signature and prompts for the login password on every ad-hoc rebuild.
    static func baseQuery(for key: SecretKey) -> [String: Any] {
        let synchronizable = AppCapabilities.isAppStore && key.synced && Self.syncEnabledProvider()
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: key.deviceOnly
                ? (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                : (kSecAttrAccessibleAfterFirstUnlock as String),
        ]
        if AppCapabilities.keychainSharingAvailable {
            q[kSecAttrAccessGroup as String] = Self.accessGroup
        }
        return q
    }

    /// Matches regardless of iCloud-sync state: every attribute is a match predicate,
    /// so a fixed synchronizable value would miss items written by the other build flavor.
    static func matchQuery(for key: SecretKey) -> [String: Any] {
        var q = baseQuery(for: key)
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return q
    }

    func read(_ key: SecretKey) -> String? {
        var q = Self.matchQuery(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            // Anything but not-found otherwise surfaces only as "unauthorized"
            // from the arr. The account name is ours, never the secret.
            if status != errSecItemNotFound {
                Self.logger.error("Keychain read failed for \(key.account, privacy: .public): \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for key: SecretKey) {
        delete(key)
        var q = Self.baseQuery(for: key)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            Self.logger.error("Keychain add failed for \(key.account, privacy: .public): \(status)")
        }
    }

    func delete(_ key: SecretKey) {
        let status = SecItemDelete(Self.matchQuery(for: key) as CFDictionary)
        // A failed delete leaves the old secret behind and `set` would add a duplicate.
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("Keychain delete failed for \(key.account, privacy: .public): \(status)")
        }
    }
}

nonisolated public extension SecretKey {
    /// Public so a reader holding a snapshot of those defaults (a sibling app)
    /// doesn't have to guess the naming.
    var plaintextDefaultsKey: String { "ArrBarr.\(account)" }
}

/// Fallback for builds without the shared Keychain access group: they can't reach
/// the data-protection Keychain, and the legacy one prompts on every ad-hoc rebuild.
nonisolated struct UserDefaultsSecretStore: SecretStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ k: SecretKey) -> String { k.plaintextDefaultsKey }
    func read(_ k: SecretKey) -> String? {
        let v = defaults.string(forKey: key(k))
        return (v?.isEmpty == false) ? v : nil
    }
    func set(_ value: String, for k: SecretKey) { defaults.set(value, forKey: key(k)) }
    func delete(_ k: SecretKey) { defaults.removeObject(forKey: key(k)) }
}

/// In-memory `SecretStore` for tests — never touches the real Keychain.
nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    init() {}
    func read(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }; return values[key.account]
    }
    func set(_ value: String, for key: SecretKey) {
        lock.lock(); defer { lock.unlock() }; values[key.account] = value
    }
    func delete(_ key: SecretKey) {
        lock.lock(); defer { lock.unlock() }; values[key.account] = nil
    }
}
