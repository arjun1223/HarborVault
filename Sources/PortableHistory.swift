import Foundation
import Security

enum PortableHistory {
    private static let service = "com.harborvault.portable-history.v1"
    private static func query(_ sourceID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: sourceID.uuidString, kSecAttrSynchronizable as String: false]
    }
    static func latest(for sourceID: UUID) throws -> Date? {
        var request = query(sourceID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw VaultError.message("Could not read portable-vault history from Keychain.") }
        return try JSONDecoder().decode(Date.self, from: bytes)
    }
    static func record(_ date: Date, for sourceID: UUID) throws {
        let previous = try latest(for: sourceID)
        let bytes = try JSONEncoder().encode(max(previous ?? .distantPast, date))
        let updates: [String: Any] = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query(sourceID) as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(sourceID)
            request[kSecValueData as String] = bytes
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw VaultError.message("Could not protect portable-vault history in Keychain.") }
        } else if status != errSecSuccess { throw VaultError.message("Could not update portable-vault history in Keychain.") }
    }
}
