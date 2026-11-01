import Foundation
import CryptoKit

enum RestoreDestination {
    case original
    case folder(UUID?)
}

extension VaultStorage {
    func trashItems(_ requested: [VaultItem], manifest: VaultManifest, vaultID: UUID, key: SymmetricKey, now: Date = Date()) throws -> VaultManifest {
        let requestedIDs = Set(requested.map(\.id))
        guard !requestedIDs.isEmpty else { return manifest }
        let byID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        for id in requestedIDs { guard byID[id]?.isDeleted == false else { throw VaultError.message("Only active items can be moved to Recently Deleted.") } }
        let roots = manifest.items.filter { requestedIDs.contains($0.id) }.filter { item in
            var parent = item.parent
            while let id = parent, let ancestor = byID[id] {
                if requestedIDs.contains(id) { return false }; parent = ancestor.parent
            }
            return true
        }
        var next = manifest; next.version = 2
        let expiry = manifest.retentionDays == 0 ? nil : Calendar.current.date(byAdding: .day, value: manifest.retentionDays, to: now)
        for root in roots {
            var members: Set<UUID> = [root.id]
            var previous = -1
            while members.count != previous {
                previous = members.count
                for item in manifest.items where !item.isDeleted {
                    if let parent = item.parent, members.contains(parent) { members.insert(item.id) }
                }
            }
            for index in next.items.indices where members.contains(next.items[index].id) {
                next.items[index].deletedAt = now
                next.items[index].permanentDeletionDate = expiry
                next.items[index].trashRootID = root.id
            }
        }
        try saveManifest(next, vaultID: vaultID, key: key)
        return next
    }
    func updateTrashRetention(_ days: Int, manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws -> VaultManifest {
        guard (0...3650).contains(days) else { throw VaultError.message("Choose a retention period from 1–3650 days, or keep until deleted manually.") }
        var next = manifest; next.version = 2; next.trashRetentionDays = days
        try saveManifest(next, vaultID: vaultID, key: key)
        return next
    }
    private func requestedTrashRoots(_ requested: [VaultItem], manifest: VaultManifest) throws -> Set<UUID> {
        let byID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        var roots: Set<UUID> = []
        for item in requested {
            guard let current = byID[item.id], current.isDeleted, let root = current.trashRootID else { throw VaultError.message("Select items in Recently Deleted.") }
            roots.insert(root)
        }
        return roots
    }
    func updateDeletionDate(_ date: Date?, for requested: [VaultItem], manifest: VaultManifest, vaultID: UUID, key: SymmetricKey, now: Date = Date()) throws -> VaultManifest {
        if let date { guard date > now, date.timeIntervalSinceReferenceDate.isFinite else { throw VaultError.message("Choose a future permanent-deletion date.") } }
        let roots = try requestedTrashRoots(requested, manifest: manifest)
        var next = manifest; next.version = 2
        for index in next.items.indices where next.items[index].trashRootID.map(roots.contains) == true {
            next.items[index].permanentDeletionDate = date
        }
        try saveManifest(next, vaultID: vaultID, key: key)
        return next
    }
    func restoreItems(_ requested: [VaultItem], manifest: VaultManifest, vaultID: UUID, key: SymmetricKey, destination: RestoreDestination = .original) throws -> VaultManifest {
        let roots = try requestedTrashRoots(requested, manifest: manifest)
        let byID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        func depth(_ item: VaultItem) -> Int {
            var depth = 0; var parent = item.parent
            while let id = parent, let entry = byID[id] { depth += 1; parent = entry.parent }
            return depth
        }
        let ordered = manifest.recentlyDeleted.filter { roots.contains($0.id) }.sorted {
            let left = depth($0), right = depth($1)
            return left == right ? $0.deletedAt! < $1.deletedAt! : left < right
        }
        var next = manifest; next.version = 2
        if case let .folder(id?) = destination {
            guard next.items.contains(where: { $0.id == id && $0.isFolder && !$0.isDeleted }) else { throw VaultError.message("Choose an active folder in this vault.") }
        }
        for root in ordered {
            guard let rootIndex = next.items.firstIndex(where: { $0.id == root.id }) else { continue }
            if case let .folder(id) = destination { next.items[rootIndex].parent = id }
            let parent = next.items[rootIndex].parent
            if let parent, !next.items.contains(where: { $0.id == parent && $0.isFolder && !$0.isDeleted }) { next.items[rootIndex].parent = nil }
            let newParent = next.items[rootIndex].parent
            let proposed = next.items[rootIndex].name
            let existing = Set(next.items.filter { !$0.isDeleted && $0.parent == newParent }.map { $0.name.lowercased() })
            var name = proposed; var counter = 2
            while existing.contains(name.lowercased()) {
                let ext = (proposed as NSString).pathExtension
                let base = ext.isEmpty ? proposed : (proposed as NSString).deletingPathExtension
                name = "\(base) (\(counter))" + (ext.isEmpty ? "" : "." + ext); counter += 1
            }
            try Self.validName(name)
            next.items[rootIndex].name = name
            for index in next.items.indices where next.items[index].trashRootID == root.id {
                next.items[index].deletedAt = nil; next.items[index].permanentDeletionDate = nil; next.items[index].trashRootID = nil
            }
        }
        try saveManifest(next, vaultID: vaultID, key: key)
        return next
    }
    func permanentlyDeleteTrash(_ requested: [VaultItem], manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws -> VaultManifest {
        let roots = try requestedTrashRoots(requested, manifest: manifest)
        let members = Set(manifest.items.filter { $0.trashRootID.map(roots.contains) == true }.map(\.id))
        guard !members.isEmpty else { return manifest }
        var next = manifest; next.version = 2
        next.items.removeAll { members.contains($0.id) }
        // Independently deleted children keep their own recovery deadline, even if
        // their former parent is permanently removed first.
        for index in next.items.indices {
            if let parent = next.items[index].parent, members.contains(parent) { next.items[index].parent = nil }
        }
        try saveManifest(next, vaultID: vaultID, key: key)
        for item in manifest.items where members.contains(item.id) && !item.isFolder {
            try? FileManager.default.removeItem(at: object(vaultID, item.id))
        }
        return next
    }
    func purgeExpiredTrash(manifest: VaultManifest, vaultID: UUID, key: SymmetricKey, now: Date = Date()) throws -> VaultManifest {
        let expired = manifest.recentlyDeleted.filter { $0.permanentDeletionDate.map { $0 <= now } == true }
        return expired.isEmpty ? manifest : try permanentlyDeleteTrash(expired, manifest: manifest, vaultID: vaultID, key: key)
    }
}

