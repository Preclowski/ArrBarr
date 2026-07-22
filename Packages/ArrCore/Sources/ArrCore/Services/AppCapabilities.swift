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

    /// Whether the shared Keychain access group is actually usable at runtime —
    /// i.e. whether this binary's signature provisions `keychain-access-groups`.
    ///
    /// Probed in EVERY build flavor, not just App Store ones. That is safe
    /// because the probe (and `KeychainSecretStore`) talk exclusively to the
    /// *data-protection* Keychain, which has no per-item ACLs and therefore no
    /// prompt path at all: it either succeeds silently or fails silently with
    /// `errSecMissingEntitlement`. The login-password prompt that used to make
    /// the Keychain unusable for OSS builds is a property of the *legacy file*
    /// Keychain, whose ACL is pinned to the code signature and so re-prompts on
    /// every rebuild of an ad-hoc-signed app — we never touch it (see
    /// `KeychainSecretStore.baseQuery`).
    ///
    /// Net effect: the *signature* decides, not the build flag. Today only the
    /// App Store entitlement files carry `keychain-access-groups` — it is a
    /// restricted entitlement, so Apple has to issue a provisioning profile for
    /// it, which the ad-hoc and self-signed identities the OSS builds use can
    /// never have. Those builds fail the probe, without any prompt, and stay on
    /// `UserDefaultsSecretStore`. Any config later given a provisioned profile
    /// upgrades itself, with no change here. Cached after first evaluation.
    public static var keychainSharingAvailable: Bool {
        if let cached = cachedProbe { return cached }
        let result = keychainProbeOverride?() ?? probeKeychainAccessGroup()
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
