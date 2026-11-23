import Foundation
import Security

// Checkpoints are stored outside the vault files. A pending checkpoint permits crash
// recovery on either side of an atomic metadata write, then narrows to the observed state.
enum LocalVaultHistory {
    private struct Checkpoint: Codable {
        var current: Data?
        var pending: Data?
    }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.harborvault.local-state.v1",
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    private static func load(_ id: UUID) throws -> Checkpoint? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.message("Could not read this vault’s protected history.") }
        return try JSONDecoder().decode(Checkpoint.self, from: data)
    }
    private static func save(_ checkpoint: Checkpoint, id: UUID) throws {
        let data = try JSONEncoder().encode(checkpoint)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(id)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw VaultError.message("Could not save this vault’s protected history.") }
        } else if status != errSecSuccess { throw VaultError.message("Could not update this vault’s protected history.") }
    }
    static func verify(_ digest: Data, id: UUID) throws {
        if let checkpoint = try load(id) {
            guard checkpoint.current == digest || checkpoint.pending == digest else {
                throw VaultError.message("This vault differs from the last version verified on this Mac. Possible rollback or outside modification. Restore through an explicitly verified backup.")
            }
            if checkpoint.pending == nil { return }
        }
        try save(Checkpoint(current: digest, pending: nil), id: id)
    }
    static func prepare(previous: Data?, next: Data, id: UUID) throws {
        if let previous {
            try verify(previous, id: id)
        } else if try load(id) != nil {
            throw VaultError.message("Protected history already exists for this vault identity.")
        }
        try save(Checkpoint(current: previous, pending: next), id: id)
    }
    static func finish(_ digest: Data, id: UUID) throws {
        try save(Checkpoint(current: digest, pending: nil), id: id)
    }
}
