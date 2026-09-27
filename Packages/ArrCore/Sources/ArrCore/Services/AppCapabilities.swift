import Foundation
import Security
import os

/// `APPSTORE` is set on the Xcode app targets only and never reaches local SwiftPM
/// packages, so ArrCore branches on this runtime value instead.
nonisolated public enum AppCapabilities {
    private static let logger = Logger(category: "AppCapabilities")

    /// `nonisolated(unsafe)`: written once at launch, before any concurrent read.
    public nonisolated(unsafe) private(set) static var isAppStore = false

    /// Must run before `ConfigStore.shared`.
    public static func configure(isAppStore: Bool) { self.isAppStore = isAppStore }

    /// Test seam: overrides the live Keychain probe when non-nil.
    public nonisolated(unsafe) static var keychainProbeOverride: (() -> Bool)?

    private nonisolated(unsafe) static var cachedProbe: Bool?

    /// Whether this binary's signature provisions `keychain-access-groups`. Safe to probe in every
    /// flavor: the data-protection Keychain has no ACLs, so it never prompts. Cached.
    public static var keychainSharingAvailable: Bool {
        if let cached = cachedProbe { return cached }
        let result = keychainProbeOverride?() ?? probeKeychainAccessGroup()
        cachedProbe = result
        return result
    }

    /// Test seam: clear the cached probe so a changed flag/override re-evaluates.
    // periphery:ignore
    public static func resetProbeForTesting() { cachedProbe = nil }

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
