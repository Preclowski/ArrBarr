import Foundation
import Security

protocol SecretStore: Sendable {
    func read(account: String) -> String?
    func write(_ value: String, account: String)
    func delete(account: String)
}

struct KeychainSecretStore: SecretStore {
    static let service = "com.preclowski.ArrBarr"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
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

    func write(_ value: String, account: String) {
        if value.isEmpty {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    func write(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        if value.isEmpty {
            storage.removeValue(forKey: account)
        } else {
            storage[account] = value
        }
    }

    func delete(account: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}
