import Foundation
import CryptoKit

enum VaultTransferMode: String, CaseIterable {
    case move
    case duplicate
}
struct VaultTransferRequest: Identifiable {
    let id = UUID()
    let source: VaultHeader
    let items: [VaultItem]
}
struct VaultTransferResult {
    let sourceManifest: VaultManifest
    let destinationManifest: VaultManifest
    let copiedRoots: [UUID]
    let moved: Bool
    let warning: String?
}
extension VaultStorage {
    func transferItems(_ requested: [VaultItem], from sourceID: UUID, sourceManifest: VaultManifest, sourceKey: SymmetricKey, to destinationID: UUID, destinationKey: SymmetricKey, mode: VaultTransferMode) throws -> VaultTransferResult {
        guard sourceID != destinationID, !requested.isEmpty else { throw VaultError.message("Choose another vault and at least one active item.") }
        let liveSource = try loadManifest(vaultID: sourceID, key: sourceKey)
        guard liveSource.items == sourceManifest.items, liveSource.trashRetentionDays == sourceManifest.trashRetentionDays else { throw VaultError.message("The source vault changed. Start the transfer again.") }
        var target = try loadManifest(vaultID: destinationID, key: destinationKey)
        target.version = 2
        let requestedIDs = Set(requested.map(\.id))
        let sourceByID = Dictionary(uniqueKeysWithValues: liveSource.items.map { ($0.id, $0) })
        for id in requestedIDs { guard sourceByID[id]?.isDeleted == false else { throw VaultError.message("Restore deleted items before sending them to another vault.") } }
        let roots = liveSource.items.filter { requestedIDs.contains($0.id) }.filter { item in
            var parent = item.parent
            while let id = parent, let ancestor = sourceByID[id] {
                if requestedIDs.contains(id) { return false }; parent = ancestor.parent
            }
            return true
        }
        let stage = folder(destinationID).appendingPathComponent(".transfer-" + UUID().uuidString, isDirectory: true)
        try Self.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        var created: [UUID] = []
        var copiedFiles: [VaultItem] = []
        var copiedRoots: [UUID] = []
        var sourceMembers: Set<UUID> = []
        var committed = false
        defer {
            if !committed { for id in created { try? FileManager.default.removeItem(at: object(destinationID, id)) } }
        }
        func copy(_ entry: VaultItem, to parent: UUID?) throws -> UUID {
            try Task.checkCancellation()
            let id = UUID()
            let name = uniqueName(entry.name, parent: parent, items: target.items)
            try Self.validName(name)
            let clone = VaultItem(id: id, parent: parent, name: name, isFolder: entry.isFolder, size: entry.size, created: entry.created, modified: entry.modified, digest: entry.digest)
            sourceMembers.insert(entry.id)
            target.items.append(clone)
            if entry.isFolder {
                for child in liveSource.items.filter({ $0.parent == entry.id && !$0.isDeleted }).sorted(by: { $0.name < $1.name }) { _ = try copy(child, to: id) }
            } else {
                try VaultCrypto.reencryptFile(source: object(sourceID, entry.id), destination: stage.appendingPathComponent(id.uuidString),
                    sourceKey: sourceKey, destinationKey: destinationKey, sourceVaultID: sourceID, destinationVaultID: destinationID,
                    sourceFileID: entry.id, destinationFileID: id, expectedSize: entry.size, expectedDigest: entry.digest!)
                copiedFiles.append(clone)
            }
            return id
        }
        for root in roots { copiedRoots.append(try copy(root, to: nil)) }
        for file in copiedFiles {
            try FileManager.default.moveItem(at: stage.appendingPathComponent(file.id.uuidString), to: object(destinationID, file.id))
            created.append(file.id)
        }
        try Task.checkCancellation()
        try saveManifest(target, vaultID: destinationID, key: destinationKey)
        committed = true
        if mode == .duplicate { return VaultTransferResult(sourceManifest: liveSource, destinationManifest: target, copiedRoots: copiedRoots, moved: false, warning: nil) }
        do {
            // Re-read committed copies before removing anything in the source vault.
            let saved = try loadManifest(vaultID: destinationID, key: destinationKey)
            guard Set(copiedRoots).isSubset(of: Set(saved.items.map(\.id))) else { throw VaultError.message("Destination catalog verification failed.") }
            for file in copiedFiles {
                let digest = try VaultCrypto.decryptFile(source: object(destinationID, file.id), key: destinationKey, vaultID: destinationID, fileID: file.id) { _ in }
                guard digest == file.digest else { throw VaultError.message("Destination copy verification failed.") }
            }
            try Task.checkCancellation()
            var remaining = liveSource; remaining.version = 2
            remaining.items.removeAll { sourceMembers.contains($0.id) }
            for index in remaining.items.indices {
                if let parent = remaining.items[index].parent, sourceMembers.contains(parent) { remaining.items[index].parent = nil }
            }
            try saveManifest(remaining, vaultID: sourceID, key: sourceKey)
            for entry in liveSource.items where sourceMembers.contains(entry.id) && !entry.isFolder {
                try? FileManager.default.removeItem(at: object(sourceID, entry.id))
            }
            return VaultTransferResult(sourceManifest: remaining, destinationManifest: target, copiedRoots: copiedRoots, moved: true, warning: nil)
        } catch {
            return VaultTransferResult(sourceManifest: liveSource, destinationManifest: target, copiedRoots: copiedRoots, moved: false,
                warning: "A destination copy was saved, but the original was kept because the move could not finish: " + error.localizedDescription)
        }
    }
}

