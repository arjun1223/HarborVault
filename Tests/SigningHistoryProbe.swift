import Foundation
import Security

enum VaultError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

// This executable operates only on randomly named records supplied by its test
// script. No real vault IDs, data, or signing material are read or exported.
@main struct SigningHistoryProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let localID = UUID(uuidString: CommandLine.arguments[2]),
              let portableID = UUID(uuidString: CommandLine.arguments[3]) else {
            throw VaultError.message("Expected mode and two disposable fixture IDs.")
        }
        let accounts = [("com.harborvault.local-state.v1", localID), ("com.harborvault.portable-history.v1", portableID)]
        let digest = Data(repeating: 41, count: 32)
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        switch CommandLine.arguments[1] {
        case "write":
            try LocalVaultHistory.prepare(previous: nil, next: digest, id: localID)
            try LocalVaultHistory.finish(digest, id: localID)
            try PortableHistory.record(date, for: portableID)
            print("Created two disposable history fixtures.")
        case "read":
            for (service, id) in accounts {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
                    kSecAttrSynchronizable as String: false, kSecReturnData as String: true,
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
                var value: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else {
                    throw VaultError.message("A rebuilt app could not read its history without authentication UI.")
                }
            }
            try LocalVaultHistory.verify(digest, id: localID)
            var rejected = false
            do { try LocalVaultHistory.verify(Data(repeating: 42, count: 32), id: localID) }
            catch { rejected = true }
            guard rejected, try PortableHistory.latest(for: portableID) == date else {
                throw VaultError.message("Protected history checks stopped enforcing their expected state.")
            }
            print("PASS: a different build reads both history services with all authentication UI forbidden.")
            print("PASS: rollback rejection and portable-history values remain intact after rebuilding.")
        case "cleanup":
            for (service, id) in accounts {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
                    kSecAttrSynchronizable as String: false]
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw VaultError.message("Could not remove a disposable history fixture.")
                }
            }
        default: throw VaultError.message("Unknown test mode.")
        }
    }
}
