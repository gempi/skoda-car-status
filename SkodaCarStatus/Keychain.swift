import Foundation
import Security

enum Keychain {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    struct Account {
        let rawValue: String

        static func apiKey(vin: String) -> Account { Account(rawValue: "apiKey.\(vin)") }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "SkodaCarStatus"

    private static func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    /// Returns `nil` only when no item exists; any other failure (locked keychain, denied access) throws.
    static func get(_ account: Account) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// An empty value removes the item.
    static func set(_ value: String, for account: Account) throws {
        guard !value.isEmpty else { return try delete(account) }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            if addStatus != errSecSuccess { throw Failure(status: addStatus) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    static func delete(_ account: Account) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw Failure(status: status) }
    }
}
