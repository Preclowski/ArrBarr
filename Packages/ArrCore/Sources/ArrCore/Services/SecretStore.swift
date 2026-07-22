import Foundation
import Security
import os

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

    /// Every secret eligible for iCloud Keychain sync: API key + password for
    /// each service, plus the OpenAI and TMDB keys. `mcpBearer` is excluded —
    /// it is `deviceOnly` and must never replicate.
    public static let syncable: [SecretKey] = {
        var keys: [SecretKey] = []
        for kind in ServiceKind.allCases {
            keys.append(.apiKey(for: kind))
            keys.append(.password(for: kind))
        }
        keys.append(.openAIKey)
        keys.append(.tmdbKey)
        return keys
    }()
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) -> String?
    func set(_ value: String, for key: SecretKey)
    func delete(_ key: SecretKey)
}

public extension SecretStore {
    /// Rewrite each given secret that currently holds a value, so the store's
    /// write path re-stamps the (possibly changed) `synchronizable` attribute.
    /// Keys with no value are skipped. Used to hard-toggle iCloud Keychain sync.
    func reapplySyncAttribute(for keys: [SecretKey]) {
        for key in keys {
            if let value = read(key) { set(value, for: key) }
        }
    }
}

/// Keychain-backed `SecretStore`. All items share the `service` namespace; the
/// `SecretKey.account` distinguishes them.
public struct KeychainSecretStore: SecretStore {
    public static let service = "pl.incred.ArrBarr"
    /// Shared Keychain access group (team-prefixed) so the app and its iOS widget
    /// extension read the same items. Applied only when the signature actually
    /// provisions the `keychain-access-groups` entitlement — the App Store
    /// entitlement files carry it, the OSS ones cannot (it is restricted, so it
    /// needs a profile issued by Apple, and those builds sign ad-hoc). The team
    /// prefix is fixed for this developer account, so a fork signed by another
    /// team fails the probe and stays on `UserDefaultsSecretStore`.
    public static let accessGroup = "9M6DR2Z85Y.pl.incred.ArrBarr.shared"
    private static let logger = Logger(category: "SecretStore")

    /// Device-local UserDefaults key mirroring `ConfigStore.iCloudSyncEnabled`.
    /// Duplicated here (not imported) so the nonisolated Keychain layer stays
    /// free of ConfigStore. Kept in sync with `ConfigStore.iCloudSyncEnabledKey`.
    /// Internal (not public): consumers toggle sync via `ConfigStore`, tests read it via `@testable`.
    static let iCloudSyncEnabledKey = "ArrBarr.iCloudSyncEnabled"

    /// Whether iCloud sync is currently enabled, read from the App Group suite
    /// (defaults to `true` when unset or unavailable). Overridable for tests.
    public static var syncEnabledProvider: @Sendable () -> Bool = {
        syncEnabled(in: WidgetDataStore.groupDefaults())
    }

    /// Pure reader for the device-local flag, defaulting to `true`.
    public static func syncEnabled(in defaults: UserDefaults?) -> Bool {
        guard let defaults, defaults.object(forKey: iCloudSyncEnabledKey) != nil
        else { return true }
        return defaults.bool(forKey: iCloudSyncEnabledKey)
    }

    public init() {}

    /// The identifying query fields + storage policy for a key. Exposed so tests
    /// can assert the synchronizable/accessibility gating without touching the
    /// real Keychain.
    ///
    /// `kSecUseDataProtectionKeychain` is set UNCONDITIONALLY and must stay that
    /// way: this store may never touch the legacy file Keychain, whose per-item
    /// ACL is bound to the code signature and so prompts for the login password
    /// on every rebuild of an ad-hoc-signed app. The data-protection Keychain has
    /// no ACLs, so every call here either succeeds or fails silently — there is
    /// no prompt path.
    ///
    /// The shared access group is added whenever the runtime probe says the
    /// entitlement is genuinely provisioned. When it is not, this type is simply
    /// never instantiated for real work — `ConfigStore.makeDefaultSecretStore`
    /// hands out `UserDefaultsSecretStore` instead.
    ///
    /// iCloud Keychain sync stays App-Store-only: it rides on the paid
    /// KVS/iCloud entitlements that only that build carries.
    public static func baseQuery(for key: SecretKey) -> [String: Any] {
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

    /// Query for read/delete. Matches the item regardless of its iCloud-sync
    /// state (`SecItemCopyMatching`/`SecItemDelete` treat every attribute as a
    /// match predicate, so a fixed synchronizable value would miss items written
    /// under the other build flavor). Use `baseQuery` only for adds.
    public static func matchQuery(for key: SecretKey) -> [String: Any] {
        var q = baseQuery(for: key)
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return q
    }

    public func read(_ key: SecretKey) -> String? {
        var q = Self.matchQuery(for: key)
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
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            Self.logger.error("Keychain add failed for \(key.account, privacy: .public): \(status)")
        }
    }

    public func delete(_ key: SecretKey) {
        SecItemDelete(Self.matchQuery(for: key) as CFDictionary)
    }
}

/// UserDefaults-backed `SecretStore` — the fallback for builds whose signature
/// does not provision the shared Keychain access group: local ad-hoc Debug, the
/// self-signed OSS DMG, forks signed by another team. Those builds cannot reach
/// the data-protection Keychain at all (`errSecMissingEntitlement`), and the
/// legacy file Keychain is off-limits because its ACL is bound to an unstable
/// ad-hoc signature — macOS would ask for the login password on every rebuild,
/// and "Always Allow" never sticks. So they keep secrets in the (sandboxed)
/// UserDefaults plist, exactly where they lived before the Keychain refactor.
/// A build whose profile does provision the group (the App Store configs) uses
/// `KeychainSecretStore` instead, and
/// `ConfigStore.migratePlaintextSecretsIntoKeychain` lifts anything this store
/// still holds over to it on the first such launch.
public struct UserDefaultsSecretStore: SecretStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ k: SecretKey) -> String { "ArrBarr.\(k.account)" }
    public func read(_ k: SecretKey) -> String? {
        let v = defaults.string(forKey: key(k))
        return (v?.isEmpty == false) ? v : nil
    }
    public func set(_ value: String, for k: SecretKey) { defaults.set(value, forKey: key(k)) }
    public func delete(_ k: SecretKey) { defaults.removeObject(forKey: key(k)) }
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
