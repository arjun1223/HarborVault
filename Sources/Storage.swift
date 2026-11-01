import Foundation
import CryptoKit
import Darwin

struct VaultHeader: Codable, Identifiable {
    var version = 1
    let id: UUID
    var name: String
    let created: Date
    var salt: Data
    var rounds: Int
    var wrappedKey: Data
    var macUnlock: VaultCrypto.MacUnlock?
}

struct VaultItem: Codable, Identifiable, Hashable {
    let id: UUID
    var parent: UUID?
    var name: String
    let isFolder: Bool
    var size: Int64
    let created: Date
    let modified: Date
    let digest: Data?
    var deletedAt: Date? = nil
    var permanentDeletionDate: Date? = nil
    var trashRootID: UUID? = nil
    var isDeleted: Bool { deletedAt != nil }
    var symbol: String {
        if isFolder { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "wav", "m4a": return "waveform"
        case "zip", "7z", "gz": return "doc.zipper"
        default: return "doc.text"
        }
    }
}
struct VaultManifest: Codable {
    var version = 2
    var items: [VaultItem] = []
    var trashRetentionDays: Int? = nil
    var retentionDays: Int { trashRetentionDays ?? 30 }
    var recentlyDeleted: [VaultItem] { items.filter { $0.isDeleted && $0.trashRootID == $0.id } }
}
struct ImportReceipt: Identifiable {
    let id = UUID()
    let source: URL
    let fingerprint: Data
    let count: Int
    let importedIDs: [UUID]
}
struct ImportResult {
    let manifest: VaultManifest
    let receipts: [ImportReceipt]
    let importedFiles: Int
}

final class VaultStorage: @unchecked Sendable {
    let root: URL
    private var lockFD: Int32 = -1
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HarborVault.noindex", isDirectory: true)
    }
    init(root: URL = VaultStorage.defaultRoot, exclusive: Bool = true) throws {
        self.root = root
        try Self.directory(root)
        if exclusive {
            lockFD = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw VaultError.message("Harbor Vault is already open in another process. Close that copy first.") }
        }
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) } }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func object(_ vaultID: UUID, _ fileID: UUID) -> URL { folder(vaultID).appendingPathComponent("objects", isDirectory: true).appendingPathComponent(fileID.uuidString) }
    func headers() throws -> [VaultHeader] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let header = try loadHeader(id)
            return header
        }.sorted { $0.created < $1.created }
    }
    func loadHeader(_ id: UUID) throws -> VaultHeader {
        let data = try Data(contentsOf: folder(id).appendingPathComponent("vault.json"))
        guard data.count < 1_000_000 else { throw VaultError.message("Vault settings are too large.") }
        let h = try JSONDecoder().decode(VaultHeader.self, from: data)
        guard h.id == id, h.version == 1, h.salt.count == 32, (600_000...2_000_000).contains(h.rounds) else { throw VaultError.message("This vault has invalid or unsupported settings.") }
        return h
    }
    func saveHeader(_ header: VaultHeader) throws {
        try Self.atomic(try JSONEncoder().encode(header), to: folder(header.id).appendingPathComponent("vault.json"))
    }
    static func headerFingerprint(_ header: VaultHeader) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(header)))
    }
    func deleteVault(_ id: UUID, expectedFingerprint: Data) throws -> String? {
        guard try Self.headerFingerprint(loadHeader(id)) == expectedFingerprint else { throw VaultError.message("Vault settings changed after authentication. Authenticate again before deleting.") }
        let tombstone = root.appendingPathComponent(".deleting-" + id.uuidString + "-" + UUID().uuidString, isDirectory: true)
        guard Darwin.rename(folder(id).path, tombstone.path) == 0 else { throw VaultError.message("Could not remove this vault. It was kept.") }
        do { try FileManager.default.removeItem(at: tombstone); return nil }
        catch { return "The vault was removed from the app, but some encrypted files could not be erased at \(tombstone.path)." }
    }
    static func atomic(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VaultError.message("Could not create an atomic vault update.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // No throwing work after the commit: callers may roll back staged objects on failure.
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw VaultError.message("Could not commit the vault update. The previous catalog was kept.") }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { _ = Darwin.fsync(parent); Darwin.close(parent) }
    }
    func create(name: String, passcode: String, mac: Bool) throws -> (VaultHeader, SymmetricKey) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 64 else { throw VaultError.message("Give your vault a name of 1–64 characters.") }
        guard passcode.count >= 10 else { throw VaultError.message("Use a passcode of at least 10 characters. A longer phrase is stronger.") }
        let id = UUID()
        let key = SymmetricKey(size: .bits256)
        let salt = try VaultCrypto.random(32)
        let passKey = try VaultCrypto.derive(passcode, salt: salt)
        let macUnlock = mac ? try VaultCrypto.makeMacUnlock(key: key, vaultID: id) : nil
        let header = VaultHeader(id: id, name: clean, created: Date(), salt: salt, rounds: VaultCrypto.rounds,
                                 wrappedKey: try VaultCrypto.seal(VaultCrypto.keyData(key), key: passKey, context: "pass/" + id.uuidString), macUnlock: macUnlock)
        let dir = folder(id)
        do {
            try Self.directory(dir.appendingPathComponent("objects", isDirectory: true))
            try saveManifest(VaultManifest(), vaultID: id, key: key)
            try saveHeader(header)
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
        return (header, key)
    }
    func passcodeKey(_ passcode: String, header: VaultHeader) throws -> SymmetricKey {
        let derived = try VaultCrypto.derive(passcode, salt: header.salt, rounds: header.rounds)
        do {
            let bytes = try VaultCrypto.open(header.wrappedKey, key: derived, context: "pass/" + header.id.uuidString)
            guard bytes.count == 32 else { throw VaultError.message("Invalid key.") }
            return SymmetricKey(data: bytes)
        } catch { throw VaultError.message("That passcode didn’t unlock this vault, or its settings are damaged.") }
    }
    func changePasscode(_ passcode: String, header: VaultHeader, key: SymmetricKey) throws -> VaultHeader {
        guard passcode.count >= 10 else { throw VaultError.message("Use at least 10 characters.") }
        var h = header
        h.salt = try VaultCrypto.random(32)
        h.rounds = VaultCrypto.rounds
        let derived = try VaultCrypto.derive(passcode, salt: h.salt)
        h.wrappedKey = try VaultCrypto.seal(VaultCrypto.keyData(key), key: derived, context: "pass/" + h.id.uuidString)
        try saveHeader(h)
        return h
    }
    func loadManifest(vaultID: UUID, key: SymmetricKey) throws -> VaultManifest {
        let encrypted = try Data(contentsOf: folder(vaultID).appendingPathComponent("catalog.sealed"))
        let decoded = try VaultCrypto.open(encrypted, key: key, context: "catalog/" + vaultID.uuidString)
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: decoded)
        try validate(manifest)
        return manifest
    }
    func saveManifest(_ manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws {
        try validate(manifest)
        var current = manifest; current.version = 2
        let sealed = try VaultCrypto.seal(JSONEncoder().encode(current), key: key, context: "catalog/" + vaultID.uuidString)
        try Self.atomic(sealed, to: folder(vaultID).appendingPathComponent("catalog.sealed"))
    }
    func validate(_ manifest: VaultManifest) throws {
        guard (1...2).contains(manifest.version), Set(manifest.items.map(\.id)).count == manifest.items.count,
              (0...3650).contains(manifest.retentionDays) else { throw VaultError.message("Invalid vault catalog.") }
        let byID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        var siblings = Set<String>()
        for item in manifest.items {
            try Self.validName(item.name)
            let scope = item.isDeleted ? "trash/" + (item.trashRootID?.uuidString ?? "invalid") : "active"
            let identity = scope + "/" + (item.parent?.uuidString ?? "root") + "/" + item.name.lowercased()
            guard siblings.insert(identity).inserted, item.size >= 0,
                  item.isFolder || item.digest?.count == 32 else { throw VaultError.message("Invalid or duplicate vault item.") }
            if item.isDeleted {
                guard let rootID = item.trashRootID, let root = byID[rootID], root.isDeleted, root.trashRootID == root.id,
                      item.deletedAt == root.deletedAt, item.permanentDeletionDate == root.permanentDeletionDate,
                      item.deletedAt!.timeIntervalSinceReferenceDate.isFinite,
                      item.permanentDeletionDate?.timeIntervalSinceReferenceDate.isFinite != false else { throw VaultError.message("Invalid Recently Deleted metadata.") }
                if item.id != rootID {
                    guard let parent = item.parent, byID[parent]?.trashRootID == rootID else { throw VaultError.message("Invalid deleted folder hierarchy.") }
                }
            } else {
                guard item.trashRootID == nil, item.permanentDeletionDate == nil,
                      item.parent.flatMap({ byID[$0] })?.isDeleted != true else { throw VaultError.message("Invalid active item metadata.") }
            }
            var parent = item.parent
            var seen: Set<UUID> = [item.id]
            while let id = parent {
                guard seen.insert(id).inserted, let p = byID[id], p.isFolder else { throw VaultError.message("Invalid folder hierarchy.") }
                parent = p.parent
            }
        }
    }
    static func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 240 else { throw VaultError.message("Use a name up to 240 bytes without / or : characters.") }
    }
    func uniqueName(_ proposed: String, parent: UUID?, items: [VaultItem]) -> String {
        let existing = Set(items.filter { $0.parent == parent && !$0.isDeleted }.map { $0.name.lowercased() })
        if !existing.contains(proposed.lowercased()) { return proposed }
        let ext = (proposed as NSString).pathExtension
        let base = ext.isEmpty ? proposed : (proposed as NSString).deletingPathExtension
        var n = 2
        while true {
            let name = "\(base) (\(n))" + (ext.isEmpty ? "" : "." + ext)
            if !existing.contains(name.lowercased()) { return name }; n += 1
        }
    }
    private func sourceValues(_ url: URL) throws -> URLResourceValues {
        guard url.isFileURL else { throw VaultError.message("Only local files can be imported.") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
        guard values.isSymbolicLink != true, values.isAliasFile != true, values.isRegularFile == true || values.isDirectory == true else { throw VaultError.message("Aliases, symbolic links, and special files cannot be imported. Import their actual files instead.") }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved != rootPath, !resolved.hasPrefix(rootPath + "/"), !rootPath.hasPrefix(resolved + "/") else { throw VaultError.message("The vault’s own storage cannot be imported.") }
        return values
    }
    func fingerprint(_ source: URL) throws -> Data {
        let values = try sourceValues(source)
        var hash = SHA256()
        if values.isDirectory == true {
            hash.update(data: Data("folder".utf8))
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let name = Data(child.lastPathComponent.utf8)
                var length = UInt64(name.count).bigEndian
                hash.update(data: withUnsafeBytes(of: &length) { Data($0) })
                hash.update(data: name)
                hash.update(data: try fingerprint(child))
            }
        } else {
            hash.update(data: Data("file".utf8))
            var fileHash = SHA256()
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            while let data = try input.read(upToCount: VaultCrypto.chunkSize), !data.isEmpty { try Task.checkCancellation(); fileHash.update(data: data) }
            hash.update(data: Data(fileHash.finalize()))
        }
        return Data(hash.finalize())
    }
    private func importedFingerprint(_ item: VaultItem, items: [VaultItem]) -> Data {
        var hash = SHA256()
        if item.isFolder {
            hash.update(data: Data("folder".utf8))
            for child in items.filter({ $0.parent == item.id }).sorted(by: { $0.name < $1.name }) {
                let name = Data(child.name.utf8)
                var length = UInt64(name.count).bigEndian
                hash.update(data: withUnsafeBytes(of: &length) { Data($0) })
                hash.update(data: name)
                hash.update(data: importedFingerprint(child, items: items))
            }
        } else {
            hash.update(data: Data("file".utf8))
            hash.update(data: item.digest!)
        }
        return Data(hash.finalize())
    }
    func importSources(_ sources: [URL], parent: UUID?, manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws -> ImportResult {
        var next = manifest
        var created: [UUID] = []
        var receipts: [ImportReceipt] = []
        let stage = folder(vaultID).appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try Self.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        var committed = false
        defer { if !committed { for id in created { try? FileManager.default.removeItem(at: object(vaultID, id)) } } }
        func add(_ source: URL, under parent: UUID?) throws -> Int {
            try Task.checkCancellation()
            let values = try sourceValues(source)
            let name = uniqueName(source.lastPathComponent, parent: parent, items: next.items)
            try Self.validName(name)
            let id = UUID()
            let now = Date()
            if values.isDirectory == true {
                next.items.append(VaultItem(id: id, parent: parent, name: name, isFolder: true, size: 0, created: now, modified: values.contentModificationDate ?? now, digest: nil))
                var count = 0
                for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { count += try add(child, under: id) }
                return count
            }
            let staged = stage.appendingPathComponent(id.uuidString)
            let (size, digest) = try VaultCrypto.encryptFile(source: source, destination: staged, key: key, vaultID: vaultID, fileID: id)
            let verified = try VaultCrypto.decryptFile(source: staged, key: key, vaultID: vaultID, fileID: id) { _ in }
            guard verified == digest else { throw VaultError.message("Import verification failed. All originals were kept.") }
            next.items.append(VaultItem(id: id, parent: parent, name: name, isFolder: false, size: size, created: now, modified: values.contentModificationDate ?? now, digest: digest))
            return 1
        }
        // Remove overlapping selections: selecting a folder and one of its files imports it once.
        let normalized = Array(Set(sources.map { $0.standardizedFileURL })).filter { source in
            !sources.contains { $0.standardizedFileURL != source && source.path.hasPrefix($0.standardizedFileURL.path + "/") }
        }.sorted { $0.path < $1.path }
        for source in normalized {
            let before = try fingerprint(source)
            let firstItem = next.items.count
            let count = try add(source, under: parent)
            guard importedFingerprint(next.items[firstItem], items: next.items) == before, try fingerprint(source) == before else { throw VaultError.message("\(source.lastPathComponent) changed during import. Nothing was removed from Finder.") }
            receipts.append(ImportReceipt(source: source, fingerprint: before, count: count, importedIDs: Array(next.items[firstItem...].map(\.id))))
        }
        for item in next.items where !item.isFolder && !manifest.items.contains(where: { $0.id == item.id }) {
            try FileManager.default.moveItem(at: stage.appendingPathComponent(item.id.uuidString), to: object(vaultID, item.id))
            created.append(item.id)
        }
        try saveManifest(next, vaultID: vaultID, key: key)
        committed = true
        return ImportResult(manifest: next, receipts: receipts, importedFiles: receipts.reduce(0) { $0 + $1.count })
    }
    func verifyOriginal(_ receipt: ImportReceipt) throws {
        guard try fingerprint(receipt.source) == receipt.fingerprint else { throw VaultError.message("\(receipt.source.lastPathComponent) has changed since import. Its original was kept.") }
    }
    func verifyStoredCopy(_ receipt: ImportReceipt, vaultID: UUID, key: SymmetricKey) throws {
        let catalog = try loadManifest(vaultID: vaultID, key: key)
        for id in receipt.importedIDs {
            guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.message("An imported item is missing from the vault. The original was kept.") }
            if !item.isFolder {
                let digest = try VaultCrypto.decryptFile(source: object(vaultID, id), key: key, vaultID: vaultID, fileID: id) { _ in }
                guard digest == item.digest else { throw VaultError.message("The stored copy failed verification. The original was kept.") }
            }
        }
    }
    func preview(_ item: VaultItem, vaultID: UUID, key: SymmetricKey) throws -> Data {
        guard !item.isFolder, item.size <= 50 * 1024 * 1024 else { throw VaultError.message("Preview supports files up to 50 MB. Export this file to open it in another app.") }
        var data = Data()
        let digest = try VaultCrypto.decryptFile(source: object(vaultID, item.id), key: key, vaultID: vaultID, fileID: item.id) { data.append($0) }
        guard digest == item.digest else { throw VaultError.message("This file failed verification.") }
        return data
    }
    func export(_ item: VaultItem, to destination: URL, manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws {
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved != rootPath, !resolved.hasPrefix(rootPath + "/") else { throw VaultError.message("Export to a location outside the encrypted storage.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VaultError.message("A file already exists there. Choose another name.") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".harbor-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        func write(_ entry: VaultItem, to url: URL) throws {
            if entry.isFolder {
                try Self.directory(url)
                for child in manifest.items.filter({ $0.parent == entry.id && $0.isDeleted == entry.isDeleted && (!$0.isDeleted || $0.trashRootID == entry.trashRootID) }) { try write(child, to: url.appendingPathComponent(child.name)) }
            } else {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VaultError.message("Could not create exported file.") }
                let out = try FileHandle(forWritingTo: url); defer { try? out.close() }
                let hash = try VaultCrypto.decryptFile(source: object(vaultID, entry.id), key: key, vaultID: vaultID, fileID: entry.id) { try out.write(contentsOf: $0) }
                guard hash == entry.digest else { throw VaultError.message("The encrypted file failed verification. Export was cancelled.") }
                try out.synchronize()
            }
        }
        try write(item, to: stage)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
    }
    func remove(_ item: VaultItem, manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws -> VaultManifest {
        try removeItems([item], manifest: manifest, vaultID: vaultID, key: key)
    }
    func removeItems(_ items: [VaultItem], manifest: VaultManifest, vaultID: UUID, key: SymmetricKey) throws -> VaultManifest {
        var ids = Set(items.map(\.id))
        var previous = -1
        while ids.count != previous {
            previous = ids.count
            for child in manifest.items { if let parent = child.parent, ids.contains(parent) { ids.insert(child.id) } }
        }
        var next = manifest
        next.items.removeAll { ids.contains($0.id) }
        try saveManifest(next, vaultID: vaultID, key: key)
        for child in manifest.items where ids.contains(child.id) && !child.isFolder { try? FileManager.default.removeItem(at: object(vaultID, child.id)) }
        return next
    }
}
