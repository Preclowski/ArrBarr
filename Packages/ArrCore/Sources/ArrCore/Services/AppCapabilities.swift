import Foundation
import Security
import os

/// Runtime replacement for the dead package-level `#if APPSTORE` gating.
///
/// `APPSTORE` is a compile condition on the Xcode *app targets* only; Xcode does
/// not propagate it to local SwiftPM packages, so `#if APPSTORE` inside ArrCore
/// is always false. Instead the app target sets `isAppStore` at launch and the
/// package branches on this runtime value.
public enum AppCapabilities {
    private static let logger = Logger(category: "AppCapabilities")

    /// True in App Store builds. Set once by the app target at launch via
    /// `configure(isAppStore:)`, before the first `ConfigStore.shared` access.
    /// `nonisolated(unsafe)`: written once at launch before any concurrent read
    /// (same pattern as `KeychainSecretStore.syncEnabledProvider`).
    public nonisolated(unsafe) private(set) static var isAppStore = false

    /// Set the build flavor. Idempotent. MUST run before `ConfigStore.shared`.
    public static func configure(isAppStore: Bool) { self.isAppStore = isAppStore }

    /// Test seam: overrides the live Keychain probe when non-nil.
    public nonisolated(unsafe) static var keychainProbeOverride: (() -> Bool)?

    private nonisolated(unsafe) static var cachedProbe: Bool?

    /// Whether the shared Keychain access group is actually usable at runtime.
    /// Only probes in App Store builds (OSS/dev never probes → never prompts,
    /// always resolves to UserDefaults storage). Cached after first evaluation.
    public static var keychainSharingAvailable: Bool {
        if let cached = cachedProbe { return cached }
        let result: Bool
        if let override = keychainProbeOverride {
            result = override()
        } else if !isAppStore {
            result = false
        } else {
            result = probeKeychainAccessGroup()
        }
        cachedProbe = result
        return result
    }

    /// Test seam: clear the cached probe so a changed flag/override re-evaluates.
    public static func resetProbeForTesting() { cachedProbe = nil }

    /// Throwaway add+copy+delete against the shared access group. Returns false
    /// on any failure (notably `errSecMissingEntitlement` when the entitlement
    /// isn't provisioned). Does not prompt — an entitlement check, not a
    /// login-Keychain access.
    private static func probeKeychainAccessGroup() -> Bool {
        let account = "appcap.__probe__"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretStore.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: KeychainSecretStore.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("1".utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        defer { SecItemDelete(base as CFDictionary) }
        if status != errSecSuccess {
            logger.notice("Keychain access group unavailable: \(status)")
            return false
        }
        return true
    }
}
