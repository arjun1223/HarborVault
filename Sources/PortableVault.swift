import Foundation
import CryptoKit
import Darwin

struct PortableExportReceipt: Identifiable {
    let id = UUID()
    let url: URL
    let sharingKey: String
    var isPublic = false
}

struct PortableImportRequest: Identifiable {
    let id = UUID()
    let url: URL
}

enum PortableVault {
    static let publicMagic = Data("HARBPB01".utf8)
    private static let magic = Data("HARBPK01".utf8)
    private static let metadataLimit = 16 * 1024 * 1024
    private struct Catalog: Codable {
        let version: Int
        let name: String
        let manifest: VaultManifest
        var sourceID: UUID? = nil
        var exportedAt: Date? = nil
    }

    private static func encodedLength(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    private static func read(_ input: FileHandle, count: Int) throws -> Data {
        let bytes = try input.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw VaultError.message("The .harb file is incomplete.") }
        return bytes
    }
    private static func readLength(_ input: FileHandle) throws -> UInt64 {
        try read(input, count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private static func encryptedSize(_ size: Int64) throws -> UInt64 {
        guard size >= 0 else { throw VaultError.message("Invalid portable file size.") }
        let length = UInt64(size)
        let chunks = max(1, (length + UInt64(VaultCrypto.chunkSize) - 1) / UInt64(VaultCrypto.chunkSize))
        let (overhead, overflowA) = chunks.multipliedReportingOverflow(by: 36)
        let (combined, overflowB) = length.addingReportingOverflow(overhead)
        let (total, overflowC) = combined.addingReportingOverflow(24)
        guard !overflowA, !overflowB, !overflowC else { throw VaultError.message("Invalid portable file size.") }
        return total
    }
    static func parseKey(_ text: String) throws -> SymmetricKey {
        guard text.utf8.count <= 160 else { throw VaultError.message("The sharing key is too long.") }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("HARB-") { value.removeFirst(5) }
        value = value.replacingOccurrences(of: "-", with: "")
        guard value.count == 64, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw VaultError.message("Enter the complete HARB sharing key supplied with this file.")
        }
        let characters = Array(value)
        var bytes = Data()
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[offset...offset + 1]), radix: 16) else {
                throw VaultError.message("Invalid sharing key.")
            }
            bytes.append(byte)
        }
        return SymmetricKey(data: bytes)
    }
    private static func keyString(_ key: SymmetricKey) -> String {
        let hex = VaultCrypto.keyData(key).map { String(format: "%02X", $0) }.joined()
        let chars = Array(hex)
        return "HARB-" + stride(from: 0, to: chars.count, by: 8)
            .map { String(chars[$0..<$0 + 8]) }.joined(separator: "-")
    }
    private static func copy(_ input: FileHandle, to output: FileHandle, count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let bytes = try read(input, count: Int(min(remaining, UInt64(VaultCrypto.chunkSize))))
            try output.write(contentsOf: bytes)
            remaining -= UInt64(bytes.count)
        }
    }

    static func isPublic(_ source: URL) throws -> Bool {
        let input = try SecurityIO.open(source)
        defer { try? input.close() }
        return try input.read(upToCount: 8) == publicMagic
    }

    static func export(storage: VaultStorage, header: VaultHeader, key: SymmetricKey, to destination: URL, publiclyReadable: Bool = false) throws -> PortableExportReceipt {
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let storagePath = storage.root.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination.isFileURL, resolved != storagePath, !resolved.hasPrefix(storagePath + "/") else {
            throw VaultError.message("Save the portable vault outside encrypted storage.")
        }
        let files = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".harb-envelope-" + UUID().uuidString)
        try VaultStorage.directory(stage)
        defer { try? files.removeItem(at: stage) }
        let inner = stage.appendingPathComponent("archive")
        let receipt = try exportLegacy(storage: storage, header: header, key: key, to: inner)
        let outer = stage.appendingPathComponent("envelope")
        try PortableEnvelope.wrap(inner, to: outer, key: parseKey(receipt.sharingKey))
        var completed = outer
        if publiclyReadable {
            // Deliberately distribute the decoding key with this public copy.
            // Encryption here provides format compatibility, not confidentiality.
            let published = stage.appendingPathComponent("public-envelope")
            guard files.createFile(atPath: published.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw VaultError.message("Could not create the public vault copy.")
            }
            let output = try FileHandle(forWritingTo: published)
            defer { try? output.close() }
            try output.write(contentsOf: publicMagic + VaultCrypto.keyData(parseKey(receipt.sharingKey)))
            let input = try SecurityIO.open(outer)
            defer { try? input.close() }
            let length = try input.seekToEnd()
            try input.seek(toOffset: 0)
            try copy(input, to: output, count: length)
            try output.synchronize()
            completed = published
        }
        try Task.checkCancellation()
        guard !files.fileExists(atPath: destination.path) else { throw VaultError.message("A file already exists there. Choose another name.") }
        try files.moveItem(at: completed, to: destination)
        return PortableExportReceipt(url: destination, sharingKey: publiclyReadable ? "" : receipt.sharingKey, isPublic: publiclyReadable)
    }
    // Retained for compatibility tests and decoding archives produced by 1.5.0.
    static func exportLegacy(storage: VaultStorage, header: VaultHeader, key: SymmetricKey, to destination: URL) throws -> PortableExportReceipt {
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let root = storage.root.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination.isFileURL, resolved != root, !resolved.hasPrefix(root + "/") else {
            throw VaultError.message("Save the .harb file outside vault storage.")
        }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw VaultError.message("A file already exists there. Choose another name.") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".harb-export-" + UUID().uuidString)
        try VaultStorage.directory(stage)
        defer { try? files.removeItem(at: stage) }
        var manifest = try storage.loadManifest(vaultID: header.id, key: key)
        manifest.items.removeAll { $0.isDeleted }
        try storage.validate(manifest)
        guard manifest.items.count <= 10_000 else { throw VaultError.message("Portable vaults currently support up to 10,000 items.") }
        let packageID = UUID()
        let sharingKey = SymmetricKey(size: .bits256)
        let catalog = Catalog(version: 2, name: header.name, manifest: manifest,
                              sourceID: header.portableSourceID ?? header.id, exportedAt: Date())
        let metadata = try VaultCrypto.seal(JSONEncoder().encode(catalog), key: sharingKey, context: "harb/catalog/" + packageID.uuidString)
        guard metadata.count <= metadataLimit else { throw VaultError.message("This portable catalog is too large.") }
        let package = stage.appendingPathComponent("package")
        guard files.createFile(atPath: package.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VaultError.message("Could not create the portable vault.")
        }
        let output = try FileHandle(forWritingTo: package)
        defer { try? output.close() }
        try output.write(contentsOf: magic + Data(packageID.uuidString.utf8) + encodedLength(UInt64(metadata.count)) + metadata)
        for item in manifest.items.filter({ !$0.isFolder }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            let encrypted = stage.appendingPathComponent("object")
            defer { try? files.removeItem(at: encrypted) }
            try VaultCrypto.reencryptFile(source: storage.object(header.id, item.id), destination: encrypted,
                sourceKey: key, destinationKey: sharingKey, sourceVaultID: header.id, destinationVaultID: packageID,
                sourceFileID: item.id, destinationFileID: item.id, expectedSize: item.size, expectedDigest: item.digest!)
            try output.write(contentsOf: encodedLength(try encryptedSize(item.size)))
            let input = try SecurityIO.open(encrypted)
            defer { try? input.close() }
            try copy(input, to: output, count: try encryptedSize(item.size))
        }
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        try files.moveItem(at: package, to: destination)
        return PortableExportReceipt(url: destination, sharingKey: keyString(sharingKey))
    }

    static func importVault(from source: URL, sharingKey: String, name: String, passcode: String, mac: Bool,
                            into storage: VaultStorage, allowPreviouslyImported: Bool = false) throws -> (VaultHeader, SymmetricKey, VaultManifest) {
        let input = try SecurityIO.open(source)
        let prefix = try input.read(upToCount: 8)
        if prefix == publicMagic {
            defer { try? input.close() }
            let bytes = try read(input, count: 32)
            let length = try input.seekToEnd()
            guard length >= 40 + 48, length <= (1 << 40) + 64 * 1024 * 1024 else { throw VaultError.message("Invalid public vault length.") }
            try input.seek(toOffset: 40)
            let marker = try read(input, count: 8)
            guard marker == PortableEnvelope.magic else { throw VaultError.message("Invalid public vault format.") }
            try input.seek(toOffset: 40)
            let stage = storage.root.appendingPathComponent(".harb-public-" + UUID().uuidString)
            try VaultStorage.directory(stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            let archive = stage.appendingPathComponent("archive")
            guard FileManager.default.createFile(atPath: archive.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VaultError.message("Could not stage the public vault.") }
            let output = try FileHandle(forWritingTo: archive)
            defer { try? output.close() }
            try copy(input, to: output, count: length - 40)
            try output.close()
            return try importVault(from: archive, sharingKey: keyString(SymmetricKey(data: bytes)), name: name,
                passcode: passcode, mac: mac, into: storage, allowPreviouslyImported: allowPreviouslyImported)
        }
        try input.close()
        let key = try parseKey(sharingKey)
        if prefix == PortableEnvelope.magic {
            let stage = storage.root.appendingPathComponent(".harb-envelope-" + UUID().uuidString)
            try VaultStorage.directory(stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            let inner = stage.appendingPathComponent("archive")
            try PortableEnvelope.unwrap(source, to: inner, key: key)
            return try importLegacy(from: inner, sharingKey: sharingKey, name: name, passcode: passcode, mac: mac, into: storage, allowPreviouslyImported: allowPreviouslyImported)
        }
        return try importLegacy(from: source, sharingKey: sharingKey, name: name, passcode: passcode, mac: mac, into: storage, allowPreviouslyImported: allowPreviouslyImported)
    }
    private static func importLegacy(from source: URL, sharingKey: String, name: String, passcode: String, mac: Bool,
                                    into storage: VaultStorage, allowPreviouslyImported: Bool) throws -> (VaultHeader, SymmetricKey, VaultManifest) {
        let key = try parseKey(sharingKey)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VaultError.message("Choose a local .harb file.")
        }
        let input = try SecurityIO.open(source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        guard try read(input, count: 8) == magic,
              let idText = String(data: try read(input, count: 36), encoding: .utf8),
              let packageID = UUID(uuidString: idText) else { throw VaultError.message("This is not a supported .harb file.") }
        let metadataLength = try readLength(input)
        guard metadataLength <= UInt64(metadataLimit), metadataLength >= 28 else { throw VaultError.message("Invalid portable catalog.") }
        let encryptedMetadata = try read(input, count: Int(metadataLength))
        let decoded: Data
        do { decoded = try VaultCrypto.open(encryptedMetadata, key: key, context: "harb/catalog/" + packageID.uuidString) }
        catch { throw VaultError.message("That sharing key didn’t unlock this .harb file, or the file is damaged.") }
        let catalog = try JSONDecoder().decode(Catalog.self, from: decoded)
        guard (1...2).contains(catalog.version), catalog.manifest.items.count <= 10_000,
              catalog.manifest.items.allSatisfy({ !$0.isDeleted }) else { throw VaultError.message("Unsupported portable catalog.") }
        try storage.validate(catalog.manifest)
        let existing = try storage.headers()
        let sourceID = catalog.sourceID ?? packageID
        let exportedAt = catalog.exportedAt
        if let exportedAt, !exportedAt.timeIntervalSinceReferenceDate.isFinite { throw VaultError.message("Invalid export date.") }
        let persistentHistory = storage.root.standardizedFileURL == VaultStorage.defaultRoot.standardizedFileURL
        let protectedDate = persistentHistory ? try PortableHistory.latest(for: sourceID) : nil
        let knownDate = existing.filter { $0.portableSourceID == sourceID }.compactMap(\.portableExportedAt).max()
        let latest = [protectedDate, knownDate].compactMap { $0 }.max()
        let repeated = existing.contains { $0.portablePackageID == packageID }
        let older = exportedAt.flatMap { date in latest.map { date <= $0 } } ?? false
        guard allowPreviouslyImported || (!repeated && !older) else {
            throw VaultError.message("This vault copy was imported before, or an equally recent/newer export is known. Enable “Import another or older copy” only if intended.")
        }
        let stage = storage.root.appendingPathComponent(".harb-import-" + UUID().uuidString)
        try VaultStorage.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let temporary = try VaultStorage(root: stage)
        let localName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var (header, localKey) = try temporary.create(name: localName.isEmpty ? catalog.name : localName, passcode: passcode, mac: mac)
        header.portablePackageID = packageID
        header.portableSourceID = sourceID
        header.portableExportedAt = exportedAt
        try temporary.saveHeader(header, key: localKey)
        header = try temporary.loadHeader(header.id)
        for item in catalog.manifest.items.filter({ !$0.isFolder }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            let size = try readLength(input)
            let offset = try input.offset()
            guard size == (try encryptedSize(item.size)), offset <= length, size <= length - offset else {
                throw VaultError.message("The portable vault contains an incomplete or invalid file.")
            }
            let encrypted = stage.appendingPathComponent("incoming")
            defer { try? FileManager.default.removeItem(at: encrypted) }
            guard FileManager.default.createFile(atPath: encrypted.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw VaultError.message("Could not stage the encrypted import.")
            }
            let output = try FileHandle(forWritingTo: encrypted)
            defer { try? output.close() }
            try copy(input, to: output, count: size)
            try output.close()
            try VaultCrypto.reencryptFile(source: encrypted, destination: temporary.object(header.id, item.id),
                sourceKey: key, destinationKey: localKey, sourceVaultID: packageID, destinationVaultID: header.id,
                sourceFileID: item.id, destinationFileID: item.id, expectedSize: item.size, expectedDigest: item.digest!)
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw VaultError.message("Unexpected data after the portable vault.") }
        try temporary.saveManifest(catalog.manifest, vaultID: header.id, key: localKey)
        try Task.checkCancellation()
        if persistentHistory, let exportedAt { try PortableHistory.record(exportedAt, for: sourceID) }
        try storage.registerImportedVault(from: temporary, id: header.id)
        return (header, localKey, catalog.manifest)
    }
}
