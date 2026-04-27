import Foundation
import Security

/// Legacy Keychain helpers used only to migrate secrets written by ArrBarr
/// 0.6.0 / 0.6.1 back into UserDefaults. Without an Apple Developer ID, the
/// app's ad-hoc signature changes every release, which makes Keychain prompt
/// the user for their login password on every launch — unusable. From 0.6.2
/// onward secrets live in the sandboxed UserDefaults plist.
enum LegacyKeychain {
    static let service = "com.preclowski.ArrBarr"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
