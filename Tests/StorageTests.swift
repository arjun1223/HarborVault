import Foundation
import CryptoKit
import LocalAuthentication
import AppKit

private var checks = 0
private func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw VaultError.message("FAILED: " + label) }
    checks += 1; print("PASS \(checks): \(label)")
}
private func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { checks += 1; print("PASS \(checks): \(label)"); return }
    throw VaultError.message("FAILED (unexpected success): " + label)
}

@main struct StorageTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--hardware") {
            try hardware()
            print("Hardware protection checks passed: \(checks)"); return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("HarborVault-tests-" + UUID().uuidString)
        try VaultStorage.directory(temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = try VaultStorage(root: temp.appendingPathComponent("vaults"))
        let sources = temp.appendingPathComponent("sources")
        try VaultStorage.directory(sources)
        let (header, key) = try storage.create(name: "Test vault", passcode: "a strong test phrase", mac: false)
        try check(try storage.headers().count == 1, "create a vault and reload its header")
        try check(header.macUnlock == nil, "passcode-only vault has no Mac unlock envelope")
        try check(try VaultCrypto.keyData(storage.passcodeKey("a strong test phrase", header: header)) == VaultCrypto.keyData(key), "correct passcode unwraps the original key")
        try rejects("incorrect passcode is rejected") { _ = try storage.passcodeKey("this is incorrect", header: header) }
        try rejects("short passcodes are rejected") { _ = try storage.create(name: "Bad", passcode: "1234", mac: false) }
        try rejects("a second process cannot open the same store") { _ = try VaultStorage(root: storage.root) }
        let (other, otherKey) = try storage.create(name: "Other vault", passcode: "a different test phrase", mac: false)
        try check(VaultCrypto.keyData(key) != VaultCrypto.keyData(otherKey), "vaults have independent random keys")
        try rejects("a different vault’s passcode cannot unlock this one") { _ = try storage.passcodeKey("a different test phrase", header: header) }

        let folder = sources.appendingPathComponent("Private folder")
        try VaultStorage.directory(folder.appendingPathComponent("Empty folder"))
        let text = Data("Secret fixture: HARBOR-TEST-CONTENT-DO-NOT-LEAK".utf8)
        let source = folder.appendingPathComponent("sensitive-name.txt")
        try text.write(to: source)
        let empty = folder.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let big = Data((0..<(VaultCrypto.chunkSize + 123)).map { UInt8($0 % 251) })
        try big.write(to: folder.appendingPathComponent("large.bin"))
        let result = try storage.importSources([folder, source], parent: nil, manifest: VaultManifest(), vaultID: header.id, key: key)
        try check(result.importedFiles == 3 && result.receipts.count == 1, "overlapping folder selections import once")
        try check(result.manifest.items.count == 5, "nested structure and empty folders are preserved")
        try check(FileManager.default.fileExists(atPath: source.path), "import keeps the Finder original")
        let reopened = try storage.loadManifest(vaultID: header.id, key: key)
        try check(reopened.items == result.manifest.items, "encrypted catalog survives reopening")
        let file = reopened.items.first { $0.name == "sensitive-name.txt" }!
        let emptyFile = reopened.items.first { $0.name == "empty.bin" }!
        let largeFile = reopened.items.first { $0.name == "large.bin" }!
        try check(try storage.preview(file, vaultID: header.id, key: key) == text, "decrypted preview matches the original")
        try check(try storage.preview(emptyFile, vaultID: header.id, key: key).isEmpty, "empty files authenticate and round-trip")
        try check(try storage.preview(largeFile, vaultID: header.id, key: key) == big, "multi-chunk files round-trip")
        let catalog = try Data(contentsOf: storage.folder(header.id).appendingPathComponent("catalog.sealed"))
        try check(catalog.range(of: Data("sensitive-name".utf8)) == nil, "filenames are absent from the on-disk catalog")
        let objectURL = storage.object(header.id, file.id)
        let originalBlob = try Data(contentsOf: objectURL)
        try check(originalBlob.range(of: text) == nil, "plaintext contents are absent from encrypted objects")
        try rejects("a different vault key cannot decrypt a file") { _ = try VaultCrypto.decryptFile(source: objectURL, key: otherKey, vaultID: header.id, fileID: file.id) { _ in } }
        try rejects("file objects cannot be swapped between identities") { _ = try VaultCrypto.decryptFile(source: objectURL, key: key, vaultID: header.id, fileID: UUID()) { _ in } }
        try rejects("file objects cannot be transplanted into another vault") { _ = try VaultCrypto.decryptFile(source: objectURL, key: key, vaultID: other.id, fileID: file.id) { _ in } }
        for (label, blob) in [
            ("tampered ciphertext is rejected", { var d = originalBlob; d[d.count - 1] ^= 0x01; return d }()),
            ("truncated ciphertext is rejected", Data(originalBlob.dropLast())),
            ("appended ciphertext is rejected", originalBlob + Data([0])),
            ("tampered file length is rejected", { var d = originalBlob; d[15] ^= 1; return d }())
        ] {
            try blob.write(to: objectURL)
            try rejects(label) { _ = try storage.preview(file, vaultID: header.id, key: key) }
        }
        try originalBlob.write(to: objectURL)
        try storage.verifyStoredCopy(result.receipts[0], vaultID: header.id, key: key)
        try check(true, "stored copies pass a fresh pre-Trash verification")
        try Data(originalBlob.dropLast()).write(to: objectURL)
        try rejects("damage after import prevents trashing the original") { try storage.verifyStoredCopy(result.receipts[0], vaultID: header.id, key: key) }
        try originalBlob.write(to: objectURL)
        try rejects("wrong vault key cannot read a catalog") { _ = try storage.loadManifest(vaultID: header.id, key: otherKey) }
        let catalogURL = storage.folder(header.id).appendingPathComponent("catalog.sealed")
        var damaged = catalog; damaged[damaged.count - 1] ^= 1
        try damaged.write(to: catalogURL)
        try rejects("tampered catalog is rejected") { _ = try storage.loadManifest(vaultID: header.id, key: key) }
        try catalog.write(to: catalogURL)

        let exportURL = temp.appendingPathComponent("exported.txt")
        try storage.export(file, to: exportURL, manifest: reopened, vaultID: header.id, key: key)
        try check(try Data(contentsOf: exportURL) == text, "export yields the verified original bytes")
        try rejects("export never overwrites an existing file") { try storage.export(file, to: exportURL, manifest: reopened, vaultID: header.id, key: key) }
        let exportFolder = temp.appendingPathComponent("exported folder")
        try storage.export(reopened.items.first { $0.parent == nil }!, to: exportFolder, manifest: reopened, vaultID: header.id, key: key)
        try check(try Data(contentsOf: exportFolder.appendingPathComponent("large.bin")) == big, "folder export preserves nested files")
        try check(FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent("Empty folder").path), "folder export preserves empty folders")
        try rejects("exports into encrypted storage are rejected") { try storage.export(file, to: storage.root.appendingPathComponent("bad.txt"), manifest: reopened, vaultID: header.id, key: key) }
        try damaged.write(to: objectURL)
        let failedExport = temp.appendingPathComponent("failed.txt")
        try rejects("corrupt exports fail without a public partial copy") { try storage.export(file, to: failedExport, manifest: reopened, vaultID: header.id, key: key) }
        try check(!FileManager.default.fileExists(atPath: failedExport.path), "failed export leaves no output file")
        try originalBlob.write(to: objectURL)

        try storage.verifyOriginal(result.receipts[0])
        try check(true, "unchanged originals pass the pre-Trash check")
        try Data("Changed after import".utf8).write(to: source)
        try rejects("changed originals are protected from Trash") { try storage.verifyOriginal(result.receipts[0]) }
        try text.write(to: source)
        try Data([1]).write(to: folder.appendingPathComponent("new-file"))
        try rejects("new files in an original folder prevent its removal") { try storage.verifyOriginal(result.receipts[0]) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("new-file"))
        let link = sources.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try rejects("symbolic links are rejected and originals kept") { _ = try storage.importSources([link], parent: nil, manifest: reopened, vaultID: header.id, key: key) }
        try rejects("the vault cannot recursively import its own storage") { _ = try storage.importSources([storage.root], parent: nil, manifest: reopened, vaultID: header.id, key: key) }
        let duplicate = try storage.importSources([source], parent: nil, manifest: reopened, vaultID: header.id, key: key)
        let duplicate2 = try storage.importSources([source], parent: nil, manifest: duplicate.manifest, vaultID: header.id, key: key)
        try check(duplicate2.manifest.items.contains { $0.name == "sensitive-name (2).txt" }, "repeated imports preserve both copies with unique names")
        var invalid = reopened
        invalid.items[0].parent = invalid.items[0].id
        try rejects("cyclic folders are rejected") { try storage.validate(invalid) }
        try rejects("path traversal names are rejected") { try VaultStorage.validName("../escape") }
        try rejects("invalid KDF settings are bounded") { _ = try VaultCrypto.derive("pass", salt: Data(repeating: 0, count: 32), rounds: Int.max) }
        let changed = try storage.changePasscode("replacement test phrase", header: header, key: key)
        try rejects("old passcode stops working after change") { _ = try storage.passcodeKey("a strong test phrase", header: changed) }
        try check(try VaultCrypto.keyData(storage.passcodeKey("replacement test phrase", header: changed)) == VaultCrypto.keyData(key), "changing passcode preserves the vault key and files")
        let removed = try storage.remove(reopened.items.first { $0.parent == nil }!, manifest: reopened, vaultID: header.id, key: key)
        try check(removed.items.isEmpty, "folder deletion removes all nested catalog entries")
        try check(FileManager.default.fileExists(atPath: source.path), "vault deletion leaves external originals untouched")
        try check(!FileManager.default.fileExists(atPath: objectURL.path), "vault deletion removes encrypted objects")

        try await modelChecks(root: temp.appendingPathComponent("model"))
        try await browserChecks(root: temp.appendingPathComponent("browser"))
        try await protectedActionChecks(root: temp.appendingPathComponent("protected"))
        try await nativeBrowserChecks(root: temp.appendingPathComponent("native-browser"))
        try zoomChecks()
        try await recoveryChecks(root: temp.appendingPathComponent("recovery"))
        try await recoveryModelChecks(root: temp.appendingPathComponent("recovery-model"))
        print("All \(checks) checks passed.")
    }

    @MainActor static func recoveryChecks(root: URL) async throws {
        let storage = try VaultStorage(root: root)
        let (source, key) = try storage.create(name: "Recovery", passcode: "fixture recovery phrase", mac: false)
        let (target, targetKey) = try storage.create(name: "Destination", passcode: "fixture destination phrase", mac: false)
        let fixtures = root.deletingLastPathComponent().appendingPathComponent("recovery-fixtures")
        try VaultStorage.directory(fixtures.appendingPathComponent("Folder/Empty"))
        let bytes = Data("PRIVATE-GENERATED-RECOVERY-FIXTURE".utf8)
        try bytes.write(to: fixtures.appendingPathComponent("Folder/note.txt"))
        try Data().write(to: fixtures.appendingPathComponent("Folder/zero.bin"))
        let large = Data(repeating: 157, count: VaultCrypto.chunkSize + 11)
        try large.write(to: fixtures.appendingPathComponent("Folder/large.bin"))
        var manifest = try storage.importSources([fixtures.appendingPathComponent("Folder")], parent: nil, manifest: VaultManifest(), vaultID: source.id, key: key).manifest
        let folder = manifest.items.first { $0.name == "Folder" }!
        let note = manifest.items.first { $0.name == "note.txt" }!
        let now = Date()
        manifest = try storage.trashItems([note], manifest: manifest, vaultID: source.id, key: key, now: now)
        let deletedNote = manifest.recentlyDeleted[0]
        try check(deletedNote.parent == folder.id && deletedNote.deletedAt == now, "Recently Deleted retains the original folder and deletion time")
        try check(deletedNote.permanentDeletionDate == Calendar.current.date(byAdding: .day, value: 30, to: now), "default recovery period is 30 days")
        try check(try storage.preview(deletedNote, vaultID: source.id, key: key) == bytes, "soft deletion retains authenticated encrypted contents")
        try check(try storage.loadManifest(vaultID: target.id, key: targetKey).recentlyDeleted.isEmpty, "Recently Deleted is isolated per vault")
        manifest = try storage.restoreItems([deletedNote], manifest: manifest, vaultID: source.id, key: key)
        try check(manifest.items.first { $0.id == note.id }?.parent == folder.id && manifest.recentlyDeleted.isEmpty, "restore returns to the prior folder and clears deletion metadata")
        manifest = try storage.trashItems([note], manifest: manifest, vaultID: source.id, key: key, now: now)
        manifest = try storage.importSources([fixtures.appendingPathComponent("Folder/note.txt")], parent: folder.id, manifest: manifest, vaultID: source.id, key: key).manifest
        manifest = try storage.restoreItems(manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key)
        try check(manifest.items.first { $0.id == note.id }?.name == "note (2).txt", "restore avoids overwriting a new file at the prior location")
        manifest = try storage.trashItems([note], manifest: manifest, vaultID: source.id, key: key, now: now)
        manifest = try storage.restoreItems(manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key, destination: .folder(nil))
        try check(manifest.items.first { $0.id == note.id }?.parent == nil, "restore can choose All files instead of the prior location")
        manifest = try storage.trashItems([note], manifest: manifest, vaultID: source.id, key: key, now: now)
        manifest = try storage.restoreItems(manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key, destination: .folder(folder.id))
        try check(manifest.items.first { $0.id == note.id }?.parent == folder.id, "restore can choose an active folder")
        manifest = try storage.trashItems([note], manifest: manifest, vaultID: source.id, key: key, now: now)
        try rejects("restore rejects nonexistent destination folders") { _ = try storage.restoreItems(manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key, destination: .folder(UUID())) }
        let custom = now.addingTimeInterval(3600)
        manifest = try storage.updateDeletionDate(custom, for: manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key, now: now)
        try check(manifest.recentlyDeleted[0].permanentDeletionDate == custom, "individual deleted items accept an exact future deletion date")
        try rejects("past permanent-deletion dates are rejected") { _ = try storage.updateDeletionDate(now.addingTimeInterval(-1), for: manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key, now: now) }
        manifest = try storage.updateTrashRetention(0, manifest: manifest, vaultID: source.id, key: key)
        try check(manifest.retentionDays == 0 && manifest.recentlyDeleted[0].permanentDeletionDate == custom, "per-vault retention changes preserve existing deletion dates")
        manifest = try storage.trashItems([folder], manifest: manifest, vaultID: source.id, key: key, now: now)
        try check(manifest.recentlyDeleted.count == 2 && manifest.items.first { $0.id == folder.id }?.permanentDeletionDate == nil, "a deleted folder and an independently deleted child retain separate deadlines")
        let purged = try storage.purgeExpiredTrash(manifest: manifest, vaultID: source.id, key: key, now: custom.addingTimeInterval(1))
        try check(!purged.items.contains { $0.id == note.id } && purged.items.contains { $0.id == folder.id }, "expiry removes only due groups and preserves keep-until-deleted groups")
        try check(!FileManager.default.fileExists(atPath: storage.object(source.id, note.id).path), "expiry removes the expired encrypted object")
        manifest = try storage.restoreItems(purged.recentlyDeleted, manifest: purged, vaultID: source.id, key: key)
        try check(manifest.items.allSatisfy { !$0.isDeleted }, "restoring a deleted folder restores its grouped descendants")
        let remainingNote = manifest.items.first { $0.name == "note.txt" }!
        manifest = try storage.trashItems([remainingNote], manifest: manifest, vaultID: source.id, key: key, now: now)
        manifest = try storage.trashItems([folder], manifest: manifest, vaultID: source.id, key: key, now: now)
        manifest = try storage.permanentlyDeleteTrash([manifest.items.first { $0.id == folder.id }!], manifest: manifest, vaultID: source.id, key: key)
        try check(manifest.recentlyDeleted.count == 1 && manifest.recentlyDeleted[0].parent == nil, "purging a former parent preserves an independently deleted child's recovery")
        manifest = try storage.restoreItems(manifest.recentlyDeleted, manifest: manifest, vaultID: source.id, key: key)
        try check(manifest.items[0].parent == nil && !manifest.items[0].isDeleted, "restore falls back to All files after the former parent was removed")
        // Reload a literal old-format catalog, with all new fields absent.
        var legacy = VaultManifest(); legacy.version = 1; legacy.items = [manifest.items[0]]
        let legacyJSON = try JSONEncoder().encode(legacy)
        let legacyDecoded = try JSONDecoder().decode(VaultManifest.self, from: legacyJSON)
        try check(legacyDecoded.items[0].deletedAt == nil && legacyDecoded.items[0].trashRootID == nil, "legacy file entries decode with absent recovery metadata")
        let oldJSON = Data("{\"version\":1,\"items\":[]}".utf8)
        try VaultStorage.atomic(VaultCrypto.seal(oldJSON, key: targetKey, context: "catalog/" + target.id.uuidString), to: storage.folder(target.id).appendingPathComponent("catalog.sealed"))
        let old = try storage.loadManifest(vaultID: target.id, key: targetKey)
        try check(old.version == 1 && old.retentionDays == 30 && old.recentlyDeleted.isEmpty, "old vault catalogs load without recovery fields")
        // Re-import a fresh tree for cross-vault streaming and failure tests.
        manifest = try storage.importSources([fixtures.appendingPathComponent("Folder")], parent: nil, manifest: manifest, vaultID: source.id, key: key).manifest
        let tree = manifest.items.first { $0.name == "Folder" }!
        let bigFile = manifest.items.first { $0.name == "large.bin" }!
        let zeroFile = manifest.items.first { $0.name == "zero.bin" }!
        let treeNote = manifest.items.first { $0.parent == tree.id && $0.name == "note.txt" }!
        let duplicated = try storage.transferItems([tree, bigFile], from: source.id, sourceManifest: manifest, sourceKey: key, to: target.id, destinationKey: targetKey, mode: .duplicate)
        try check(duplicated.sourceManifest.items == manifest.items && !duplicated.moved && duplicated.copiedRoots.count == 1, "duplicate keeps the source and collapses overlapping selected folders")
        let copiedBig = duplicated.destinationManifest.items.first { $0.name == "large.bin" }!
        let copiedZero = duplicated.destinationManifest.items.first { $0.name == "zero.bin" }!
        try check(try storage.preview(copiedBig, vaultID: target.id, key: targetKey) == large, "cross-vault transfer streams and verifies multi-chunk files")
        try check(try storage.preview(copiedZero, vaultID: target.id, key: targetKey).isEmpty, "cross-vault transfer preserves empty files")
        try check(copiedBig.id != bigFile.id && duplicated.destinationManifest.items.contains { $0.name == "Empty" && $0.isFolder }, "transfers assign fresh identities and preserve empty folders")
        try rejects("a transferred object rejects the source key") { _ = try storage.preview(copiedBig, vaultID: target.id, key: key) }
        let encrypted = try Data(contentsOf: storage.object(target.id, copiedBig.id))
        try check(encrypted.range(of: large.prefix(128)) == nil, "transfers persist ciphertext rather than plaintext")
        try rejects("same-vault transfer is rejected") { _ = try storage.transferItems([tree], from: source.id, sourceManifest: manifest, sourceKey: key, to: source.id, destinationKey: key, mode: .move) }
        try rejects("wrong destination key leaves source untouched") { _ = try storage.transferItems([tree], from: source.id, sourceManifest: manifest, sourceKey: key, to: target.id, destinationKey: key, mode: .move) }
        let blobURL = storage.object(source.id, bigFile.id), original = try Data(contentsOf: blobURL)
        try Data(original.dropLast()).write(to: blobURL)
        try rejects("source corruption aborts move before committing destination") { _ = try storage.transferItems([tree], from: source.id, sourceManifest: manifest, sourceKey: key, to: target.id, destinationKey: targetKey, mode: .move) }
        try check(try storage.loadManifest(vaultID: target.id, key: targetKey).items == duplicated.destinationManifest.items, "failed transfer leaves the destination catalog unchanged")
        try check(try storage.loadManifest(vaultID: source.id, key: key).items == manifest.items, "failed transfer leaves the source catalog unchanged")
        try check(try FileManager.default.contentsOfDirectory(atPath: storage.folder(target.id).path).allSatisfy { !$0.hasPrefix(".transfer-") }, "failed transfer removes its staged encrypted files")
        try original.write(to: blobURL)
        var stale = manifest; stale.items.removeAll { $0.id == zeroFile.id }
        try rejects("stale source snapshots cannot overwrite newer files") { _ = try storage.transferItems([tree], from: source.id, sourceManifest: stale, sourceKey: key, to: target.id, destinationKey: targetKey, mode: .move) }
        manifest = try storage.trashItems([treeNote], manifest: manifest, vaultID: source.id, key: key, now: now)
        try rejects("deleted files must be restored before transferring") { _ = try storage.transferItems([manifest.recentlyDeleted[0]], from: source.id, sourceManifest: manifest, sourceKey: key, to: target.id, destinationKey: targetKey, mode: .duplicate) }
        let moved = try storage.transferItems([tree], from: source.id, sourceManifest: manifest, sourceKey: key, to: target.id, destinationKey: targetKey, mode: .move)
        try check(moved.moved && moved.warning == nil && !moved.sourceManifest.items.contains { $0.id == tree.id }, "move removes the source only after committing and verifying the destination")
        try check(!FileManager.default.fileExists(atPath: blobURL.path), "successful move removes the old encrypted object")
        try check(moved.destinationManifest.items.contains { $0.name == "Folder (2)" }, "transfers preserve existing destination names with a numbered folder")
        try check(moved.sourceManifest.recentlyDeleted.first?.id == treeNote.id && moved.sourceManifest.recentlyDeleted.first?.parent == nil, "moving a folder preserves its independently deleted children in source recovery")
        try check(moved.destinationManifest.items.filter { $0.name == "note.txt" }.count == 1, "transfers omit independently deleted children")
    }

    @MainActor static func recoveryModelChecks(root: URL) async throws {
        let model = AppModel(root: root)
        model.idleMinutes = 5
        model.create(name: "Source", passcode: "fixture source phrase", mac: false); try await wait(model)
        let sourceID = model.header!.id
        let storage = model.storage!
        let key = try storage.passcodeKey("fixture source phrase", header: model.header!)
        let (target, _) = try storage.create(name: "Target", passcode: "fixture target phrase", mac: false)
        model.reload()
        let url = root.deletingLastPathComponent().appendingPathComponent("model-recovery.txt")
        try Data("model recovery fixture".utf8).write(to: url)
        model.manifest = try storage.importSources([url], parent: nil, manifest: model.manifest, vaultID: sourceID, key: key).manifest
        let item = model.manifest.items[0]
        model.manifest = try storage.trashItems([item], manifest: model.manifest, vaultID: sourceID, key: key)
        try check(model.visible.isEmpty && model.fileCount == 0, "active browser and counts exclude Recently Deleted")
        model.showRecentlyDeleted(true); model.setSelection([item.id], lead: item.id)
        model.restoreSelection()
        try check(model.restoreRequest?.items.first?.id == item.id && model.manifest.items[0].isDeleted, "restore presents confirmation before changing the catalog")
        model.confirmRestore(model.restoreRequest!, destination: .original); try await wait(model)
        try check(model.restoreRequest == nil && !model.manifest.items[0].isDeleted, "confirmed restore clears its sheet and restores the item")
        model.showRecentlyDeleted(false); model.setSelection([item.id], lead: item.id)
        model.beginTransfer()
        try check(model.transferRequest != nil && model.transferDestinationID == target.id && !model.transferAuthenticated, "sending files starts with an unverified destination")
        model.confirmTransfer(mode: .move)
        try check(!model.busy && model.error != nil && model.manifest.items.count == 1, "move is blocked before destination verification")
        model.error = nil
        model.authenticateTransferDestination(passcode: "fixture target phrase"); try await wait(model)
        try check(model.transferAuthenticated, "destination passcode grants a fresh transfer permit")
        model.selectTransferDestination(target.id)
        try check(!model.transferAuthenticated, "changing destination clears prior transfer verification")
        model.authenticateTransferDestination(passcode: "fixture target phrase"); try await wait(model)
        model.checkIdle(now: Date().addingTimeInterval(61))
        try check(!model.transferAuthenticated, "transfer verification expires after 60 seconds")
        model.authenticateTransferDestination(passcode: "fixture target phrase"); try await wait(model)
        model.confirmTransfer(mode: .duplicate); try await wait(model)
        try check(model.transferRequest == nil && model.manifest.items.count == 1, "verified duplicate completes and retains the source")
        model.setSelection([item.id], lead: item.id); model.beginTransfer(); model.lock()
        try check(model.transferRequest == nil && !model.transferAuthenticated, "locking discards transfer credentials and pending request")
        model.unlock(passcode: "fixture source phrase"); try await wait(model)
        model.manifest = try storage.trashItems([item], manifest: model.manifest, vaultID: sourceID, key: key, now: Date().addingTimeInterval(-31 * 86400))
        model.lock(); model.purgeExpiredTrashIfNeeded()
        try check(try storage.loadManifest(vaultID: sourceID, key: key).recentlyDeleted.count == 1, "locked vaults are not modified by expiry checks")
        model.unlock(passcode: "fixture source phrase"); try await wait(model)
        try check(model.manifest.items.isEmpty && model.unlocked, "next unlock removes expired copies while keeping the vault open")
    }

    @MainActor static func modelChecks(root: URL) async throws {
        let model = AppModel(root: root)
        model.create(name: "UI state", passcode: "model test phrase", mac: false)
        try await wait(model)
        try check(model.unlocked && model.vaults.count == 1, "model creates and opens a vault")
        model.query = "private query"; model.selection = UUID()
        model.folderID = UUID()
        model.preview = PreviewContent(item: VaultItem(id: UUID(), parent: nil, name: "private", isFolder: false, size: 6, created: Date(), modified: Date(), digest: Data(repeating: 0, count: 32)), data: Data("secret".utf8))
        model.lock()
        try check(!model.unlocked && model.manifest.items.isEmpty && model.query.isEmpty && model.selection == nil && model.preview == nil && model.folderID == nil, "locking clears content, search, selection, and preview")
        model.unlock(passcode: "model test phrase")
        model.lock()
        try await wait(model)
        try check(!model.unlocked, "an in-flight unlock cannot repopulate a locked window")
        model.unlock(passcode: "model test phrase")
        try await wait(model)
        try check(model.unlocked, "passcode unlock works through the model")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(!model.unlocked, "sleep notification locks the vault")
        model.unlock(passcode: "model test phrase"); try await wait(model)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(!model.unlocked, "user-session change locks the vault")
        model.unlock(passcode: "model test phrase"); try await wait(model)
        model.idleMinutes = 5
        model.checkIdle(now: Date().addingTimeInterval(301))
        try check(!model.unlocked, "idle deadline locks the vault without a real-time wait")
    }
    @MainActor static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !model.busy else { throw VaultError.message("Model operation timed out.") }
        if let error = model.error { throw VaultError.message(error) }
    }
    @MainActor static func browserChecks(root: URL) async throws {
        let ids = (0..<6).map { _ in UUID() }
        let single = BrowserSelection.click(ids[1], ordered: ids, selected: [], anchor: nil, shift: false, command: false)
        try check(single.ids == [ids[1]], "plain click selects one item")
        let range = BrowserSelection.click(ids[4], ordered: ids, selected: single.ids, anchor: single.anchor, shift: true, command: false)
        try check(range.ids == Set(ids[1...4]), "Shift-click selects an inclusive range")
        let reverse = BrowserSelection.click(ids[0], ordered: ids, selected: range.ids, anchor: range.anchor, shift: true, command: false)
        try check(reverse.ids == Set(ids[0...1]), "Shift selection preserves its original anchor")
        let toggle = BrowserSelection.click(ids[1], ordered: ids, selected: range.ids, anchor: range.anchor, shift: false, command: true)
        try check(toggle.ids == Set(ids[2...4]), "Command-click toggles an item without clearing others")
        let union = BrowserSelection.click(ids[5], ordered: ids, selected: [ids[0]], anchor: ids[4], shift: true, command: true)
        try check(union.ids == [ids[0], ids[4], ids[5]], "Command-Shift adds a range to existing selection")
        try check(BrowserSelection.marquee(hits: [ids[0], ids[2]], initial: [ids[1]], shift: false, command: false) == [ids[0], ids[2]], "selection rectangle replaces the current set")
        try check(BrowserSelection.marquee(hits: [ids[0]], initial: [ids[1]], shift: true, command: false) == [ids[0], ids[1]], "Shift selection rectangle adds to the current set")
        try check(BrowserSelection.marquee(hits: [ids[0], ids[1]], initial: [ids[1], ids[2]], shift: false, command: true) == [ids[0], ids[2]], "Command selection rectangle toggles intersecting items")
        let model = AppModel(root: root)
        model.create(name: "Browser", passcode: "browser test phrase", mac: false)
        try await wait(model)
        let now = Date()
        func folder(_ id: UUID, _ name: String, _ parent: UUID? = nil) -> VaultItem { VaultItem(id: id, parent: parent, name: name, isFolder: true, size: 0, created: now, modified: now, digest: nil) }
        model.manifest.items = [folder(ids[0], "A"), folder(ids[1], "B"), folder(ids[2], "C", ids[0])]
        model.select(ids[0]); model.navigate(ids[0]); model.navigate(ids[2])
        try check(model.canGoBack && model.folderID == ids[2], "folder visits build back history")
        model.goBack()
        try check(model.folderID == ids[0] && model.canGoForward, "back restores the previous folder")
        model.goBack()
        try check(model.folderID == nil && model.selectionIDs == [ids[0]], "back restores a previous selection")
        model.goForward()
        try check(model.folderID == ids[0], "forward restores the next folder")
        model.navigate(ids[1])
        try check(!model.canGoForward, "a new visit discards forward history")
        model.goUp()
        try check(model.folderID == nil, "enclosing-folder navigation returns to the parent")
        model.query = "A"; model.navigate(ids[0]); model.goBack()
        try check(model.query == "A" && model.folderID == nil, "history restores a previous filename search")
        model.query = ""; model.selectAll()
        try check(model.selectionIDs == [ids[0], ids[1]], "Select All is limited to the current visible folder")
        model.select(ids[0]); model.moveSelection(by: 1, extend: true)
        try check(model.selectionIDs == [ids[0], ids[1]], "Shift-arrow extends selection")
        model.selectionIDs = [ids[0], ids[2]]
        model.query = ""; model.folderID = nil
        try check(model.topLevelSelection.map(\.id) == [ids[0]], "batch actions omit children of already-selected folders")
        model.lock()
        try check(model.selectionIDs.isEmpty && !model.canGoBack && !model.canGoForward && model.quickViewItems.isEmpty, "locking clears multiple selection, history, and grouped previews")
        let text = Data("A thumbnail fixture\nSecond line\n".utf8)
        let thumbnail = ThumbnailRenderer.render(text, name: "sample.txt")
        try check(thumbnail != nil && thumbnail!.size.width <= 512, "text files generate bounded in-memory thumbnails")
        try check(ThumbnailRenderer.render(Data([0, 255, 0]), name: "unknown.bin") == nil, "unsupported binary files fall back to a file icon")
        let cache = ThumbnailCache()
        let item = VaultItem(id: UUID(), parent: nil, name: "sample.txt", isFolder: false, size: Int64(text.count), created: now, modified: now, digest: Data(repeating: 0, count: 32))
        var delivered = false
        cache.request(item, load: { Thread.sleep(forTimeInterval: 0.05); return text }, completion: { _ in delivered = true })
        cache.clear()
        try await Task.sleep(nanoseconds: 120_000_000)
        try check(!delivered, "locking cancels thumbnail callbacks and discards late decoded images")
    }
    static func hardware() throws {
        try check(SecureEnclave.isAvailable, "Secure Enclave is available outside the build sandbox")
        let id = UUID(); let key = SymmetricKey(size: .bits256)
        let wrapped = try VaultCrypto.makeMacUnlock(key: key, vaultID: id)
        try check(!wrapped.privateKeyBlob.isEmpty && wrapped.ephemeralPublicKey.count == 65, "create hardware-bound user-presence key and wrapped vault key")
        let noUI = LAContext(); noUI.interactionNotAllowed = true
        try rejects("hardware refuses to unwrap without user authentication") { _ = try VaultCrypto.macKey(wrapped, vaultID: id, context: noUI) }
    }
    @MainActor static func protectedActionChecks(root: URL) async throws {
        try check(QuickViewKeyAction.action(for: 123) == .previous && QuickViewKeyAction.action(for: 124) == .next, "Quick View uses left/right to switch files")
        try check(QuickViewKeyAction.action(for: 125) == .ignore && QuickViewKeyAction.action(for: 126) == .ignore, "Quick View ignores up/down file navigation")
        try check(QuickViewKeyAction.action(for: 49) == .close && QuickViewKeyAction.action(for: 53) == .close, "Space and Escape close Quick View")
        let model = AppModel(root: root.appendingPathComponent("vaults"))
        model.create(name: "Delete fixture", passcode: "deletion fixture phrase", mac: false)
        try await wait(model)
        let storage = model.storage!
        let header = model.header!
        let now = Date()
        let permit = VaultActionPermit(vaultID: header.id, headerFingerprint: try VaultStorage.headerFingerprint(header), authenticatedAt: now)
        try check(permit.allowsDeletion(of: header, confirmation: "DELETE Delete fixture", now: now), "fresh authorization accepts the exact DELETE phrase")
        try check(!permit.allowsDeletion(of: header, confirmation: "delete Delete fixture", now: now), "deletion phrase is case-sensitive")
        try check(!permit.allowsDeletion(of: header, confirmation: "DELETE Delete fixture ", now: now), "deletion phrase rejects extra characters")
        try check(!permit.allowsDeletion(of: header, confirmation: "DELETE Delete fixture", now: now.addingTimeInterval(61)), "deletion authorization expires after 60 seconds")
        try check(!permit.isFresh(for: UUID(), now: now) && !permit.isFresh(for: header.id, now: now.addingTimeInterval(-1)), "authorization is bound to its vault and does not accept future timestamps")
        model.preview = PreviewContent(item: VaultItem(id: UUID(), parent: nil, name: "fixture.txt", isFolder: false, size: 6, created: now, modified: now, digest: Data(repeating: 0, count: 32)), data: Data("secret".utf8))
        model.quickViewItem = model.preview!.item
        model.previewLostFocus()
        try check(model.unlocked && model.viewerLocked && model.preview == nil, "leaving the file window locks only the viewer and clears readable preview state")
        model.authenticateViewer(passcode: "wrong fixture passcode")
        while model.viewerAuthenticating { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.viewerLocked && model.unlocked && model.viewerAuthError != nil, "an incorrect viewer passcode preserves the locked viewer and unlocked vault")
        model.authenticateViewer(passcode: "deletion fixture phrase")
        while model.viewerAuthenticating { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(!model.viewerLocked && model.unlocked, "fresh passcode verification unlocks only the viewer")
        model.previewLostFocus()
        model.closeQuickView()
        try check(model.unlocked && !model.viewerLocked && model.quickViewItem == nil, "closing a locked viewer does not lock its vault")
        model.beginDeleteVault(header)
        model.confirmDeleteVault("DELETE Delete fixture")
        try check(try storage.headers().count == 1 && !model.actionAuthenticated, "an exact DELETE phrase alone cannot delete a vault")
        model.error = nil
        model.authenticateProtectedAction(passcode: "deletion fixture phrase")
        try await wait(model)
        try check(model.actionAuthenticated && !model.unlocked, "fresh passcode verification authorizes the action without reopening the browser")
        model.checkIdle(now: Date().addingTimeInterval(61))
        try check(!model.actionAuthenticated && model.actionAuthenticatedAt == nil, "expired action authorization is actively cleared")
        model.authenticateProtectedAction(passcode: "deletion fixture phrase"); try await wait(model)
        let key = try storage.passcodeKey("deletion fixture phrase", header: header)
        let changed = try storage.changePasscode("changed fixture phrase", header: header, key: key)
        model.confirmDeleteVault("DELETE Delete fixture")
        do { try await wait(model) } catch { }
        try check(try storage.headers().count == 1 && model.error != nil, "changing vault settings invalidates a pending deletion authorization")
        model.error = nil
        model.authenticateProtectedAction(passcode: "changed fixture phrase"); try await wait(model)
        let (sibling, _) = try storage.create(name: "Keep fixture", passcode: "keep fixture phrase", mac: false)
        model.confirmDeleteVault("DELETE Delete fixture"); try await wait(model)
        try check(try storage.headers().map(\.id) == [sibling.id], "confirmed deletion removes only the authenticated fixture vault")
        try check(!FileManager.default.fileExists(atPath: storage.folder(header.id).path), "confirmed deletion removes the fixture vault directory")
        _ = changed

        let sourceFolder = root.appendingPathComponent("sources")
        try VaultStorage.directory(sourceFolder)
        let source = sourceFolder.appendingPathComponent("share.txt")
        let bytes = Data("Disposable share fixture".utf8); try bytes.write(to: source)
        let siblingKey = try storage.passcodeKey("keep fixture phrase", header: sibling)
        let imported = try storage.importSources([source], parent: nil, manifest: VaultManifest(), vaultID: sibling.id, key: siblingKey)
        let item = imported.manifest.items.first!
        let shareBase = root.appendingPathComponent("share-temp")
        var files: VaultShareFiles? = try VaultShareFiles.prepare([item], storage: storage, manifest: imported.manifest, vaultID: sibling.id, key: siblingKey, temporaryBase: shareBase)
        let preparedFolder = files!.folder
        try check(try Data(contentsOf: files!.urls[0]) == bytes, "sharing stages a verified readable copy in an isolated temporary folder")
        let permissions = try FileManager.default.attributesOfItem(atPath: preparedFolder.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o700, "temporary sharing directory is owner-only")
        files = nil
        try check(!FileManager.default.fileExists(atPath: preparedFolder.path), "temporary sharing copies are removed when their session is released")
        try check(try Data(contentsOf: source) == bytes, "sharing preserves the original source")
        let objectURL = storage.object(sibling.id, item.id)
        let original = try Data(contentsOf: objectURL)
        try Data(original.dropLast()).write(to: objectURL)
        try rejects("damaged vault files cannot be prepared for sharing") {
            _ = try VaultShareFiles.prepare([item], storage: storage, manifest: imported.manifest, vaultID: sibling.id, key: siblingKey, temporaryBase: shareBase)
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: shareBase.path).isEmpty, "a failed share export cleans partial plaintext copies")
        try original.write(to: objectURL)
        model.reload(); model.selectedVaultID = sibling.id
        model.unlock(passcode: "keep fixture phrase"); try await wait(model)
        model.setSelection([item.id], lead: item.id)
        model.beginShare()
        try check(!model.unlocked && model.protectedAction?.kind == .share && !model.actionAuthenticated, "sharing requests fresh verification even when the vault was unlocked")
        model.prepareVerifiedShare()
        try check(model.error != nil && !model.busy, "sharing cannot stage files before fresh authentication")
        model.error = nil; model.authenticateProtectedAction(passcode: "keep fixture phrase"); try await wait(model)
        try check(model.actionAuthenticated, "correct vault passcode authorizes sharing")
        model.cancelProtectedAction()
        try check(!model.actionAuthenticated && model.protectedAction == nil, "cancelling sharing clears its authorization")
    }
    @MainActor static func nativeBrowserChecks(root: URL) async throws {
        // Off-screen regression: use only generated fixtures. No windows are
        // constructed, no authentication dialogs appear, no personal store is read.
        let model = AppModel(root: root)
        model.create(name: "Existing fixture", passcode: "existing fixture phrase", mac: false)
        try await wait(model)
        let sourceRoot = root.deletingLastPathComponent().appendingPathComponent("native-sources")
        try VaultStorage.directory(sourceRoot)
        let source = sourceRoot.appendingPathComponent("existing-file.txt")
        let bytes = Data("An existing file saved before the browser is constructed.".utf8)
        try bytes.write(to: source)
        let other = sourceRoot.appendingPathComponent("other-file.txt")
        try Data("A second selection fixture".utf8).write(to: other)
        model.importFiles([source, other]); try await wait(model); model.importResult = nil
        let savedID = model.header!.id
        model.lock(); model.unlock(passcode: "existing fixture phrase"); try await wait(model)
        try check(model.header?.id == savedID && model.visible.count == 2, "a saved nonempty vault reopens with its existing catalog")
        for grid in [false, true] {
            // Set the backing field temporarily and restore the prior preference.
            let originalGrid = model.grid
            model.grid = grid
            defer { model.grid = originalGrid }
            let coordinator = NativeFileBrowser.Coordinator(model)
            let scroll = NativeFileBrowser.makeScrollView(coordinator: coordinator)
            scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
            let collection = scroll.documentView as! FileCollectionView
            coordinator.items = model.visible; collection.items = model.visible
            var rendered: NSCollectionViewItem?
            let exception = HarborCatchException {
                collection.reloadData()
                rendered = coordinator.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
                _ = rendered?.view
                collection.layoutSubtreeIfNeeded()
            }
            try check(exception == nil, "nonempty \(grid ? "grid" : "list") browser creates its registered item without an AppKit exception: \(exception ?? "OK")")
            try check((rendered as? FileCollectionItem)?.canvas.entry?.name == "existing-file.txt", "\(grid ? "grid" : "list") browser retains the existing file entry")
            let canvas = (rendered as! FileCollectionItem).canvas
            canvas.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
            try check(canvas.hitTest(NSPoint(x: 60, y: 60)) === canvas, "\(grid ? "grid" : "list") file canvas receives mouse hits instead of discarding them")
            let frame = collection.collectionViewLayout!.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame
            let localHit = NSPoint(x: frame.midX, y: frame.midY)
            let routed = collection.hitTest(collection.convert(localHit, to: collection.superview))
            try check(routed is FileItemCanvas || routed === collection, "\(grid ? "grid" : "list") collection hit-testing routes around AppKit’s private wrappers")
            var smallCount = 0; var openCount = 0; var groupCount = 0
            collection.onSmallPreview = { item, _ in smallCount += 1; model.smallPreviewItem = item }
            collection.onOpenItem = { _ in openCount += 1; groupCount = model.selectionIDs.count }
            let single = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let double = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 2, pressure: 1)!
            model.clearSelection()
            canvas.mouseDown(with: single)
            try check(model.selectionIDs == [model.visible[0].id], "\(grid ? "grid" : "list") real cell mouse-down immediately selects the file")
            try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.1) * 1_000_000_000))
            try check(smallCount == 0 && openCount == 0, "\(grid ? "grid" : "list") single click selects without opening any preview")
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0.2, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            collection.keyDown(with: space)
            try check(smallCount == 1 && model.smallPreviewItem != nil && openCount == 0, "\(grid ? "grid" : "list") Space alone opens the small preview")
            collection.keyDown(with: space)
            try check(model.smallPreviewItem == nil && model.unlocked, "\(grid ? "grid" : "list") Space dismisses the small preview without locking")
            smallCount = 0
            canvas.mouseDown(with: single); canvas.mouseDown(with: double)
            try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.1) * 1_000_000_000))
            try check(openCount == 1 && smallCount == 0, "\(grid ? "grid" : "list") double-click opens only the full viewer")
            model.selectAll()
            canvas.mouseDown(with: single); canvas.mouseDown(with: double)
            try check(groupCount == 2 && model.selectionIDs.count == 2, "\(grid ? "grid" : "list") double-click preserves a multiple selection for the grouped viewer")
            model.smallPreviewItem = model.visible[0]
            model.closeSmallPreview()
            try check(model.unlocked && model.smallPreviewItem == nil, "dismissing a small preview preserves the unlocked vault")
            model.quickViewItem = model.visible[0]; model.quickViewItems = model.visible
            model.closeQuickView()
            try check(model.unlocked && model.quickViewItem == nil, "closing the full preview preserves the unlocked vault")
            collection.dataSource = nil; collection.delegate = nil; collection.model = nil; scroll.documentView = nil
        }
        let key = try model.storage!.passcodeKey("existing fixture phrase", header: model.header!)
        try check(try model.storage!.preview(model.visible[0], vaultID: savedID, key: key) == bytes, "existing encrypted file contents still decrypt after native browser setup")
        model.lock()
    }
    @MainActor static func zoomChecks() throws {
        try check(PreviewZoom.clamp(0.01) == 0.25 && PreviewZoom.clamp(30) == 5, "preview zoom respects its minimum and maximum")
        try check(PreviewZoom.clamp(.nan) == 1, "invalid preview zoom returns to fit")
        let fitted = PreviewZoom.fit(image: NSSize(width: 1200, height: 600), viewport: NSSize(width: 636, height: 436))
        try check(fitted == NSSize(width: 600, height: 300), "image fit preserves aspect ratio within the viewport")
        let scroll = PinchImageScrollView(frame: NSRect(x: 0, y: 0, width: 636, height: 436))
        scroll.imageView.image = NSImage(size: NSSize(width: 1200, height: 600))
        scroll.layoutSubtreeIfNeeded()
        try check(scroll.allowsMagnification && scroll.minMagnification == 0.25 && scroll.maxMagnification == 5, "native image viewport enables trackpad magnification")
        scroll.setControlZoom(2)
        try check(abs(scroll.magnification - 2) < 0.001, "toolbar zoom controls the native image magnification")
        var synchronized: Double = 0
        scroll.onZoom = { synchronized = $0 }
        scroll.magnification = 3
        scroll.publishZoom()
        try check(abs(synchronized - 3) < 0.001, "native magnification reports the updated zoom to the preview controls")
        scroll.setControlZoom(1)
        try check(abs(scroll.magnification - 1) < 0.001, "Fit resets native image magnification")
        scroll.onZoom = nil; scroll.imageView.image = nil; scroll.documentView = nil
    }
}
