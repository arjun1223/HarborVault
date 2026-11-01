import Foundation
import CryptoKit

struct VaultActionPermit {
    let vaultID: UUID
    let headerFingerprint: Data
    let authenticatedAt: Date
    func isFresh(for id: UUID, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(authenticatedAt)
        return id == vaultID && age >= 0 && age <= 60
    }
    func allowsDeletion(of header: VaultHeader, confirmation: String, now: Date = Date()) -> Bool {
        isFresh(for: header.id, now: now) && confirmation == "DELETE \(header.name)"
    }
}

struct VaultActionRequest: Identifiable {
    enum Kind { case delete, share }
    let id = UUID()
    let kind: Kind
    let header: VaultHeader
    var items: [VaultItem] = []
}

