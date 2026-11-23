import Foundation
import CryptoKit
import LocalAuthentication
import AppKit
import VisionKit
import UniformTypeIdentifiers
import CoreText
import ImageIO
import PDFKit
import AVFoundation
import Security

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
        if CommandLine.arguments.contains("--security-keychain") {
            try keychainChecks()
            print("Protected history checks passed: \(checks)")
            return
        }
        if CommandLine.arguments.contains("--hardware") {
            try hardware()
            print("Hardware protection checks passed: \(checks)"); return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("HarborVault-tests-" + UUID().uuidString)
        try VaultStorage.directory(temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let index = CommandLine.arguments.firstIndex(of: "--browser-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try VaultStorage.directory(destination)
            let storage = try VaultStorage(root: temp.appendingPathComponent("browser-fixture-vault"))
            let (header, key) = try storage.create(name: "Browser fixture", passcode: "disposable fixture password", mac: false)
            let folder = temp.appendingPathComponent("Documents")
            try VaultStorage.directory(folder.appendingPathComponent("Empty folder"))
            try Data("Harbor browser compatibility fixture.\nNothing personal here.".utf8).write(to: folder.appendingPathComponent("hello.txt"))
            try Data().write(to: folder.appendingPathComponent("empty.bin"))
            let multi = Data((0..<(VaultCrypto.chunkSize + 119)).map { UInt8($0 % 251) })
            try multi.write(to: folder.appendingPathComponent("multi.bin"))
            try Data("<script>throw new Error('should never run')</script>".utf8).write(to: folder.appendingPathComponent("unsafe.html"))
            let imported = try storage.importSources([folder], parent: nil, manifest: VaultManifest(), vaultID: header.id, key: key)
            let v1 = try PortableVault.exportLegacy(storage: storage, header: header, key: key, to: destination.appendingPathComponent("legacy.harb"))
            let v2 = try PortableVault.export(storage: storage, header: header, key: key, to: destination.appendingPathComponent("hardened.harb"))
            _ = try PortableVault.export(storage: storage, header: header, key: key, to: destination.appendingPathComponent("public.harb"), publiclyReadable: true)
            try ProtectedSharingKey.save(v2.sharingKey, password: "disposable key-file password", to: destination.appendingPathComponent("fixture.harbkey"))
            let metadata: [String: Any] = ["legacyKey": v1.sharingKey, "hardenedKey": v2.sharingKey,
                "keyFilePassword": "disposable key-file password", "manifest": try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported.manifest))]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: destination.appendingPathComponent("fixture.json"))
            print("Generated disposable browser compatibility fixtures.")
            return
        }
        if CommandLine.arguments.contains("--drops") {
            try await dropChecks(root: temp.appendingPathComponent("drops"))
            print("All screenshot-drop checks passed: \(checks)"); return
        }
        if CommandLine.arguments.contains("--ocr") {
            try await ocrChecks(root: temp.appendingPathComponent("ocr"))
            print("All OCR checks passed: \(checks)"); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--video-fixture"), CommandLine.arguments.indices.contains(index + 1) {
            let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let storage = try VaultStorage(root: temp.appendingPathComponent("video-vault"))
            let (header, key) = try storage.create(name: "Video test", passcode: "disposable video passcode", mac: false)
            let result = try storage.importSources([fixture], parent: nil, manifest: VaultManifest(), vaultID: header.id, key: key)
            guard let item = result.manifest.items.first,
                  let video = try await storage.loadPreview(item, vaultID: header.id, key: key).video else {
                throw VaultError.message("Video preview did not open.")
            }
            defer { video.close() }
            let frames = AVAssetImageGenerator(asset: video.asset)
            let (image, _) = try await frames.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            try check(image.width > 0, "AVFoundation decodes a video frame directly from the encrypted vault")
            return
        }
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
        let largeObject = storage.object(header.id, largeFile.id)
        let reader = try VaultCrypto.ChunkReader(source: largeObject, key: key, vaultID: header.id,
                                                 fileID: largeFile.id, expectedSize: largeFile.size)
        try check(try reader.readBytes(at: Int64(VaultCrypto.chunkSize), upTo: 200) == Data(big.suffix(123)),
                  "video seeks authenticate and read the final encrypted chunk directly")
        try check(try reader.readBytes(at: 17, upTo: 42) == big.subdata(in: 17..<59),
                  "video can seek backwards across encrypted chunks")
        let damagedVideo = temp.appendingPathComponent("damaged-video")
        var damagedVideoBytes = try Data(contentsOf: largeObject)
        damagedVideoBytes[damagedVideoBytes.count - 1] ^= 1
        try damagedVideoBytes.write(to: damagedVideo)
        let badReader = try VaultCrypto.ChunkReader(source: damagedVideo, key: key, vaultID: header.id, fileID: largeFile.id, expectedSize: largeFile.size)
        try rejects("video does not return bytes from a tampered chunk") {
            _ = try badReader.readBytes(at: Int64(VaultCrypto.chunkSize), upTo: 123)
        }
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
        let rotation = try storage.changePasscode("replacement test phrase", header: header, key: key)
        let changed = rotation.header
        try rejects("old passcode stops working after change") { _ = try storage.passcodeKey("a strong test phrase", header: changed) }
        let rotatedKey = try storage.passcodeKey("replacement test phrase", header: changed)
        try check(VaultCrypto.keyData(rotatedKey) != VaultCrypto.keyData(key), "changing passcode rotates the vault key")
        try check(try storage.preview(file, vaultID: header.id, key: rotatedKey) == text, "password rotation preserves file contents")
        try rejects("an old header and password cannot decrypt current objects") {
            let oldKey = try storage.passcodeKey("a strong test phrase", header: header)
            _ = try VaultCrypto.decryptFile(source: objectURL, key: oldKey, vaultID: header.id, fileID: file.id) { _ in }
        }
        let removed = try storage.remove(reopened.items.first { $0.parent == nil }!, manifest: reopened, vaultID: header.id, key: rotatedKey)
        try check(removed.items.isEmpty, "folder deletion removes all nested catalog entries")
        try check(FileManager.default.fileExists(atPath: source.path), "vault deletion leaves external originals untouched")
        try check(!FileManager.default.fileExists(atPath: objectURL.path), "vault deletion removes encrypted objects")

        // Construct the old local header format explicitly, using disposable bytes.
        let (migrationHeader, migrationKey) = try storage.create(name: "Legacy migration fixture", passcode: "old fixture passphrase", mac: false)
        var oldHeader = migrationHeader
        oldHeader.version = 1
        oldHeader.authenticationTag = nil
        oldHeader.wrappedKey = try VaultCrypto.seal(VaultCrypto.keyData(migrationKey),
            key: VaultCrypto.derive("old fixture passphrase", salt: oldHeader.salt), context: "pass/" + oldHeader.id.uuidString)
        try VaultStorage.atomic(JSONEncoder().encode(oldHeader), to: storage.folder(oldHeader.id).appendingPathComponent("vault.json"))
        let oldLoaded = try storage.loadHeader(oldHeader.id)
        let oldUnlocked = try storage.passcodeKey("old fixture passphrase", header: oldLoaded)
        try check(VaultCrypto.keyData(oldUnlocked) == VaultCrypto.keyData(migrationKey), "legacy local headers still unlock with their original password")
        let legacyImport = try storage.importSources([source], parent: nil, manifest: VaultManifest(), vaultID: oldLoaded.id, key: oldUnlocked)
        let migrated = try storage.changePasscode("new fixture passphrase", header: oldLoaded, key: oldUnlocked)
        try check(migrated.header.version == 2 && migrated.header.authenticationTag?.count == 32,
                  "changing a legacy password upgrades its settings authentication")
        try check(VaultCrypto.keyData(migrated.key) != VaultCrypto.keyData(oldUnlocked), "legacy migration rotates the actual data key")
        try check(try storage.preview(legacyImport.manifest.items[0], vaultID: oldLoaded.id, key: migrated.key) == text,
                  "legacy migration retains the original readable file bytes")
        let cancelledRotation = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try storage.changePasscode("cancelled fixture password", header: migrated.header, key: migrated.key)
        }
        do {
            _ = try await cancelledRotation.value
            throw VaultError.message("Cancelled rotation unexpectedly completed.")
        } catch is CancellationError {
            let intactHeader = try storage.loadHeader(oldLoaded.id)
            let intactKey = try storage.passcodeKey("new fixture passphrase", header: intactHeader)
            try check(try storage.preview(legacyImport.manifest.items[0], vaultID: oldLoaded.id, key: intactKey) == text,
                      "cancelling key rotation leaves the previous password and files usable")
        }

        try await secretClipboardChecks()
        try await portableVaultChecks(root: temp.appendingPathComponent("portable"))
        try await modelChecks(root: temp.appendingPathComponent("model"))
        try await browserChecks(root: temp.appendingPathComponent("browser"))
        try await protectedActionChecks(root: temp.appendingPathComponent("protected"))
        try await nativeBrowserChecks(root: temp.appendingPathComponent("native-browser"))
        try zoomChecks()
        try await recoveryChecks(root: temp.appendingPathComponent("recovery"))
        try await recoveryModelChecks(root: temp.appendingPathComponent("recovery-model"))
        try await dropChecks(root: temp.appendingPathComponent("drops"))
        try await ocrChecks(root: temp.appendingPathComponent("ocr"))
        print("All \(checks) checks passed.")
    }

    @MainActor static func ocrChecks(root: URL) async throws {
        try VaultStorage.directory(root)
        func content(_ data: Data, _ name: String, id: UUID = UUID(), folder: Bool = false) -> PreviewContent {
            PreviewContent(item: VaultItem(id: id, parent: nil, name: name, isFolder: folder, size: Int64(data.count), created: Date(), modified: Date(), digest: nil), data: data)
        }
        func makeImage(_ lines: [String]) throws -> CGImage {
            let context = CGContext(data: nil, width: 1400, height: 500, bitsPerComponent: 8, bytesPerRow: 5600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1400, height: 500))
            for (index, value) in lines.enumerated() {
                let string = CFAttributedStringCreate(nil, value as CFString, [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 66, nil), kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary)!
                context.textPosition = CGPoint(x: 65, y: 330 - index * 115)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            return context.makeImage()!
        }
        func png(_ image: CGImage, orientation: Int? = nil) throws -> Data {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { throw VaultError.message("Generated OCR fixture could not be encoded.") }
            return data as Data
        }
        let image = try makeImage(["HARBOR VAULT OCR 2468", "LOCAL TEXT EXAMPLE"])
        let imageContent = content(try png(image), "Generated screenshot.png")
        try check(TextRecognition.supports(imageContent), "OCR is available for a supported image preview")
        let result = try await Task.detached { try TextRecognition.recognize(imageContent) }.value
        try check(result.pages.count == 1 && result.text.uppercased().contains("HARBOR VAULT OCR 2468"), "Vision recognizes text from a generated image")
        try check(result.text.range(of: "HARBOR")!.lowerBound < result.text.range(of: "LOCAL")!.lowerBound, "recognized image lines retain top-to-bottom reading order")
        let rotatedContext = CGContext(data: nil, width: 500, height: 1400, bitsPerComponent: 8, bytesPerRow: 2000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        rotatedContext.translateBy(x: 0, y: 1400); rotatedContext.rotate(by: -.pi / 2)
        rotatedContext.draw(image, in: CGRect(x: 0, y: 0, width: 1400, height: 500))
        let oriented = content(try png(rotatedContext.makeImage()!, orientation: 8), "Oriented screenshot.png")
        let orientationResult = try await Task.detached { try TextRecognition.recognize(oriented) }.value
        try check(orientationResult.text.uppercased().contains("HARBOR VAULT OCR 2468"), "OCR honors image orientation metadata before recognizing text")
        let blank = content(try png(makeImage([])), "Blank.png")
        let empty = try await Task.detached { try TextRecognition.recognize(blank) }.value
        try check(empty.isEmpty && empty.text.isEmpty, "images without text produce a clean empty result")
        let invalid = content(Data("not an image".utf8), "File.bin")
        try check(!TextRecognition.supports(invalid), "unsupported file types do not offer OCR")
        try rejects("OCR rejects unsupported input explicitly") { _ = try TextRecognition.recognize(invalid) }
        try check(!TextRecognition.supports(content(imageContent.data, "Folder", folder: true)), "folders do not offer OCR")
        try rejects("malformed PDFs fail without a partial result") { _ = try TextRecognition.recognize(content(Data("%PDF-invalid".utf8), "Broken.pdf")) }
        let cancelled = TextRecognitionCancellation(); cancelled.cancel()
        try rejects("cancelled recognition stops before handling readable content") { _ = try TextRecognition.recognize(imageContent, cancellation: cancelled) }
        let pdfData = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &media, nil)!
        for text in ["FIRST DOCUMENT PAGE 2468", "SECOND DOCUMENT PAGE 9753"] {
            pdfContext.beginPDFPage(nil); pdfContext.draw(try makeImage([text]), in: CGRect(x: 0, y: 0, width: 1000, height: 357)); pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        let pdfContent = content(pdfData as Data, "Generated scan.pdf")
        try check((PDFDocument(data: pdfContent.data)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "scanned-PDF fixtures have no existing selectable text layer")
        let pages = OCRFixtureProgress()
        let pdfResult = try await Task.detached { try TextRecognition.recognize(pdfContent, progress: { pages.add($0, $1) }) }.value
        try check(pdfResult.pages.count == 2 && pdfResult.pages[0].text.contains("FIRST DOCUMENT PAGE 2468") && pdfResult.pages[1].text.contains("SECOND DOCUMENT PAGE 9753"), "OCR recognizes every scanned PDF page in order")
        try check(pdfResult.text.contains("Page 1") && pdfResult.text.contains("Page 2"), "copied multi-page text includes page separators")
        try check(pages.values == ["1/2", "2/2"], "multi-page recognition reports page progress")
        let cancelPDF = TextRecognitionCancellation()
        try rejects("multi-page OCR can be cancelled between pages") { _ = try TextRecognition.recognize(pdfContent, cancellation: cancelPDF, progress: { _, _ in cancelPDF.cancel() }) }
        let manyData = NSMutableData(); let manyContext = CGContext(consumer: CGDataConsumer(data: manyData)!, mediaBox: &media, nil)!
        for _ in 0...TextRecognition.pageLimit { manyContext.beginPDFPage(nil); manyContext.endPDFPage() }
        manyContext.closePDF()
        try rejects("oversized page counts are rejected before rasterization") { _ = try TextRecognition.recognize(content(manyData as Data, "Too many pages.pdf")) }
        let session = RecognizedTextSession()
        session.start(imageContent, worker: { _, _, report in report(1, 1); return result })
        try await waitOCR(session)
        try check(session.visible && !session.running && session.result == result, "Text mode presents selectable recognized text when recognition completes")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try check(session.copy(to: board) && board.string(forType: .string) == result.text, "the Copy action writes recognized text only to the requested test pasteboard")
        session.toggle(imageContent)
        try check(!session.visible && session.result == nil && !session.copy(to: board), "toggling Text off clears the result and disables copying")
        session.start(imageContent, worker: { _, _, _ in throw VaultError.message("Generated OCR failure") })
        try await waitOCR(session)
        try check(session.error == "Generated OCR failure" && session.result == nil && !session.running, "recognition errors remain inside the text pane without a stale result")
        session.start(imageContent, worker: { _, _, _ in Thread.sleep(forTimeInterval: 0.08); return result })
        session.clear(); try await Task.sleep(nanoseconds: 130_000_000)
        try check(!session.visible && session.result == nil && session.error == nil && session.progress.isEmpty, "late OCR completion cannot repopulate a cleared preview")
        session.start(imageContent, worker: { _, _, _ in Thread.sleep(forTimeInterval: 0.08); return result })
        session.start(pdfContent, worker: { _, _, _ in return pdfResult })
        try await waitOCR(session); try await Task.sleep(nanoseconds: 130_000_000)
        try check(session.result == pdfResult, "an earlier file's OCR cannot overwrite a later recognition result")
        session.clear()
        let model = AppModel(root: root.appendingPathComponent("store"))
        model.create(name: "OCR fixture", passcode: "fixture recognition phrase", mac: false); try await wait(model)
        let catalog = model.storage!.folder(model.header!.id).appendingPathComponent("catalog.sealed")
        let originalCatalog = try Data(contentsOf: catalog)
        model.quickViewItem = imageContent.item; model.preview = imageContent
        model.toggleRecognizedText(); try await waitOCR(model.viewerTextRecognition)
        try check((model.viewerTextRecognition.imageAnalysis?.transcript ?? model.viewerTextRecognition.result?.text)?.contains("HARBOR VAULT OCR 2468") == true, "the preview Text button starts local OCR for its current file")
        model.previewLostFocus()
        try check(model.viewerLocked && model.unlocked && !model.viewerTextRecognition.visible && model.viewerTextRecognition.result == nil && model.viewerTextRecognition.imageAnalysis == nil, "leaving a full viewer clears OCR and locks only that viewer")
        model.preview = imageContent; model.toggleRecognizedText()
        try check(!model.viewerTextRecognition.running && !model.viewerTextRecognition.visible, "a locked viewer cannot start OCR with stale preview bytes")
        model.viewerLocked = false
        model.viewerTextRecognition.start(imageContent, worker: { _, _, _ in result }); try await waitOCR(model.viewerTextRecognition)
        model.smallPreviewItem = imageContent.item; model.smallPreview = imageContent
        model.smallTextRecognition.start(imageContent, worker: { _, _, _ in result }); try await waitOCR(model.smallTextRecognition)
        model.closeSmallPreview()
        try check(model.unlocked && !model.smallTextRecognition.visible && model.viewerTextRecognition.visible, "dismissing small-preview text leaves the main vault and other viewer unchanged")
        model.closeQuickView()
        try check(model.unlocked && !model.viewerTextRecognition.visible && model.viewerTextRecognition.result == nil, "closing the full preview clears its OCR without locking the vault")
        model.viewerTextRecognition.start(imageContent, worker: { _, _, _ in Thread.sleep(forTimeInterval: 0.08); return result })
        model.smallTextRecognition.start(imageContent, worker: { _, _, _ in Thread.sleep(forTimeInterval: 0.08); return result })
        model.lock(); try await Task.sleep(nanoseconds: 130_000_000)
        try check(!model.unlocked && model.viewerTextRecognition.result == nil && model.smallTextRecognition.result == nil && !model.viewerTextRecognition.running && !model.smallTextRecognition.running, "locking the vault clears both OCR sessions and discards late results")
        try check(try Data(contentsOf: catalog) == originalCatalog, "OCR never modifies the encrypted vault catalog or adds plaintext text files")
    }
    @MainActor static func waitOCR(_ session: RecognizedTextSession) async throws {
        let deadline = Date().addingTimeInterval(25)
        while session.running && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !session.running else { throw VaultError.message("OCR fixture timed out") }
    }

    @MainActor static func dropChecks(root: URL) async throws {
        try VaultStorage.directory(root)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(image.bitmapData!, 145, image.bytesPerRow * image.pixelsHigh)
        let png = image.representation(using: .png, properties: [:])!
        let tiff = image.tiffRepresentation!
        let finder = root.appendingPathComponent("Finder image.png"); try png.write(to: finder)
        let temporary = root.appendingPathComponent("staged")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setData(png, forType: .png); item.setData(tiff, forType: .tiff)
        board.writeObjects([item])
        try check(FileDropRequest.supports(board), "image-only screenshot drags are accepted without a Finder URL")
        let screenshot = try FileDropRequest.read(board)
        try check(screenshot.sources.count == 1, "multiple image representations of one screenshot import once")
        let prepared = try screenshot.prepare(temporaryBase: temporary)
        try check(prepared.urls.count == 1 && prepared.originalURLs.isEmpty, "raw screenshot preparation creates no Finder-original receipts")
        try check(try Data(contentsOf: prepared.urls[0]) == png, "dropped PNG bytes are preserved without re-encoding")
        let mode = try FileManager.default.attributesOfItem(atPath: prepared.urls[0].path)[.posixPermissions] as! NSNumber
        let folderMode = try FileManager.default.attributesOfItem(atPath: prepared.folder.path)[.posixPermissions] as! NSNumber
        try check(mode.intValue == 0o600 && folderMode.intValue == 0o700, "temporary screenshot files and folders use owner-only permissions")
        prepared.remove()
        try check(!FileManager.default.fileExists(atPath: prepared.folder.path), "temporary screenshot preparation cleans up on completion")
        let tiffPrepared = try FileDropRequest(sources: [.image(tiff)]).prepare(temporaryBase: temporary)
        try check(try Data(contentsOf: tiffPrepared.urls[0]) == tiff && ["tif", "tiff"].contains(tiffPrepared.urls[0].pathExtension), "TIFF-only screenshot drags preserve the data and correct extension")
        tiffPrepared.remove()
        board.clearContents()
        let fileItem = NSPasteboardItem(); fileItem.setString(finder.absoluteString, forType: .fileURL); fileItem.setData(png, forType: .png)
        board.writeObjects([fileItem])
        let fileRequest = try FileDropRequest.read(board)
        let fromFinder = try fileRequest.prepare(temporaryBase: temporary)
        try check(fromFinder.urls == [finder] && fromFinder.originalURLs == [finder], "Finder URL wins over its duplicate image representation and keeps original provenance")
        fromFinder.remove()
        try check(FileManager.default.fileExists(atPath: finder.path), "cleaning a drop never deletes the Finder original")
        board.clearContents(); let web = NSPasteboardItem(); web.setString("https://example.invalid/image.png", forType: .URL); board.writeObjects([web])
        try check(!FileDropRequest.supports(board), "a website URL alone is not treated as a local screenshot")
        try rejects("unsupported drops produce an explicit error") { _ = try FileDropRequest.read(board) }
        try rejects("invalid image data is rejected") { _ = try FileDropRequest(sources: [.image(Data("not an image".utf8))]).prepare(temporaryBase: temporary) }
        try check(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty, "failed image decoding leaves no temporary files")
        let multi = FixtureDropPromise(names: ["One.png", "Two.png"], data: png)
        let promised = try FileDropRequest(sources: [.promise(multi)]).prepare(temporaryBase: temporary)
        try check(promised.urls.count == 2 && promised.originalURLs.isEmpty, "multiple promised screenshots of the same type all arrive")
        try check(try promised.urls.allSatisfy { try Data(contentsOf: $0) == png }, "promised screenshot copies remain valid after their coordinated callback")
        promised.remove()
        let bad = FixtureDropPromise(names: ["Failed.png"], data: png, behavior: .failure)
        try rejects("a source-app promise failure is surfaced") { _ = try FileDropRequest(sources: [.promise(bad)]).prepare(temporaryBase: temporary) }
        let missing = FixtureDropPromise(names: ["Missing.png"], data: png, behavior: .never)
        try rejects("unfinished screenshot promises time out instead of hanging") { _ = try FileDropRequest(sources: [.promise(missing)]).prepare(temporaryBase: temporary, promiseTimeout: 0.06) }
        let escaped = FixtureDropPromise(names: ["Escape.png"], data: png, behavior: .outside(finder))
        try rejects("promised files outside the private destination are rejected") { _ = try FileDropRequest(sources: [.promise(escaped)]).prepare(temporaryBase: temporary) }
        try check(try Data(contentsOf: finder) == png && FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty, "promise failures keep external files intact and clean staging")
        // Use an isolated pasteboard with a real AppKit promise provider. No
        // actual drag session, app window, screen capture, or clipboard is used.
        board.clearContents()
        let delegate = FixtureNativePromiseDelegate(data: png)
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: delegate)
        board.writeObjects([provider])
        try check(FileDropRequest.supports(board), "native screenshot file-promise types are registered")
        let native = try FileDropRequest.read(board)
        try check(native.sources.count == 1, "a native file-promise pasteboard produces one retained promise, not a duplicate thumbnail")
        if case .promise(let retained) = native.sources[0] {
            try check(retained is NativeDroppedFilePromise, "native screenshot promises use the AppKit receiver adapter")
        } else { throw VaultError.message("Expected an AppKit file promise") }
        // AppKit fulfills this provider only during a real OS drag session.
        // Delivery semantics above use deterministic providers instead; a real
        // screen-thumbnail drag is intentionally left to an approved UI check.
        let late = try FileDropStaging(base: temporary)
        late.remove()
        try VaultStorage.directory(late.promises)
        let lateURL = late.promises.appendingPathComponent("Late.png"); try png.write(to: lateURL)
        try rejects("late screenshot delivery cannot reopen cancelled staging") { try late.capture(lateURL) }
        try check(!FileManager.default.fileExists(atPath: late.folder.path), "late deliveries remove any newly arrived temporary image")
        withExtendedLifetime((provider, delegate)) {}
        let model = AppModel(root: root.appendingPathComponent("store"))
        model.create(name: "Drop fixtures", passcode: "fixture screenshot phrase", mac: false); try await wait(model)
        let storage = model.storage!, header = model.header!
        let key = try storage.passcodeKey("fixture screenshot phrase", header: header)
        let region = NativeDropContainer(); region.model = model
        try check(Set(FileDropRequest.registeredTypes).isSubset(of: Set(region.registeredDraggedTypes)), "the native drop region accepts URLs, raw images, and screenshot promises")
        model.importDrop(FileDropRequest(sources: [.image(png), .file(finder), .promise(FixtureDropPromise(names: ["Delivered.png"], data: png))]), temporaryBase: temporary)
        try await wait(model)
        let result = model.importResult!
        try check(result.importedFiles == 3 && model.manifest.items.count == 3, "mixed Finder, raw screenshot, and promised-file drops all encrypt and import")
        try check(result.receipts.count == 1 && result.receipts[0].source == finder, "only genuine Finder files offer the copy-then-Trash action")
        try check(ImportSheetItem(result: result).id == ImportSheetItem(result: result).id, "import completion sheets have a stable identity even for screenshot-only imports")
        for stored in model.manifest.items { try check(try storage.preview(stored, vaultID: header.id, key: key) == png, "the encrypted dropped copy matches generated image bytes") }
        try check(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty, "successful encrypted imports immediately remove plaintext drop staging")
        try check(!model.canImportDrop, "a pending original-removal confirmation cannot be replaced by another drop")
        model.importResult = nil
        model.showRecentlyDeleted(true); try check(!model.canImportDrop, "Recently Deleted rejects incoming drops")
        model.showRecentlyDeleted(false)
        model.importDrop(FileDropRequest(sources: [.promise(FixtureDropPromise(names: ["Pending.png"], data: png, behavior: .never))]), temporaryBase: temporary)
        try await Task.sleep(nanoseconds: 70_000_000)
        model.lock(); try await wait(model)
        try check(!model.unlocked && model.manifest.items.isEmpty && model.importResult == nil, "locking cancels an in-flight screenshot delivery without reopening the vault")
        try check(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty, "cancelled screenshot delivery removes its private staging folder")
        try check(try storage.loadManifest(vaultID: header.id, key: key).items.count == 3, "cancelled screenshot delivery leaves the prior encrypted catalog intact")
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
        var macHeader = model.vaults[0]
        // The placeholder envelope exercises the UI gate without prompting for authentication.
        macHeader.macUnlock = VaultCrypto.MacUnlock(privateKeyBlob: Data(), ephemeralPublicKey: Data(), wrappedKey: Data())
        let modelKey = try model.storage!.passcodeKey("model test phrase", header: model.header!)
        try model.storage!.saveHeader(macHeader, key: modelKey)
        macHeader = try model.storage!.loadHeader(macHeader.id)
        model.vaults[0] = macHeader
        try check(!model.canStartAutomaticMacUnlock, "passcode-only idle lock does not queue Mac authentication")
        model.unlock(passcode: "model test phrase"); try await wait(model)
        model.checkIdle(now: Date().addingTimeInterval(301))
        try check(!model.unlocked && model.canStartAutomaticMacUnlock, "idle lock queues inline Touch ID for a Mac-enabled vault")
        model.lock()
        model.choose(macHeader.id)
        try check(model.canStartAutomaticMacUnlock, "reopening a locked Mac-enabled vault queues one automatic prompt")
        model.showSettings = true
        try check(!model.canStartAutomaticMacUnlock, "automatic authentication waits while preferences are open")
        model.showSettings = false
        model.beginAutomaticMacUnlock()
        try check(!model.canStartAutomaticMacUnlock && !model.busy && !model.unlocked,
                  "automatic Touch ID waits for an embedded view without starting a system prompt")
        model.lock()
        try check(model.inlineTouchIDContext == nil && model.inlineTouchIDMessage == nil,
                  "locking clears pending inline Touch ID")
        model.choose(macHeader.id)
        model.lock()
        try check(!model.canStartAutomaticMacUnlock, "explicit locking clears a queued authentication prompt")

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
        model.query = ""
        let originalOrder = model.visible.map(\.id)
        model.fileSort = .largest
        let visibleFiles = model.visible.filter { !$0.isFolder }
        try check(visibleFiles.map(\.size) == visibleFiles.map(\.size).sorted(by: >), "size sorting orders files from largest to smallest")
        model.fileSort = .name
        try check(model.visible.map(\.id) == originalOrder, "returning to name sort restores the browser order")
        model.selectAll()
        try check(model.selectionIDs == [ids[0], ids[1]], "Select All is limited to the current visible folder")
        model.select(ids[0]); model.moveSelection(by: 1, extend: true)
        try check(model.selectionIDs == [ids[0], ids[1]], "Shift-arrow extends selection")
        model.selectionIDs = [ids[0], ids[2]]
        model.query = ""; model.folderID = nil
        try check(model.topLevelSelection.map(\.id) == [ids[0]], "batch actions omit children of already-selected folders")
        model.lock()
        try check(model.selectionIDs.isEmpty && !model.canGoBack && !model.canGoForward && model.quickViewItems.isEmpty, "locking clears multiple selection, history, and grouped previews")
        let text = Data("A thumbnail fixture\nSecond line\n".utf8)
        let thumbnail = ThumbnailRenderer.render(text)
        try check(thumbnail != nil && thumbnail!.size.width <= 512, "text files generate bounded in-memory thumbnails")
        try check(ThumbnailRenderer.render(Data([0, 255, 0])) == nil, "unsupported binary files fall back to a file icon")
        let cache = ThumbnailCache()
        let item = VaultItem(id: UUID(), parent: nil, name: "sample.txt", isFolder: false, size: Int64(text.count), created: now, modified: now, digest: Data(repeating: 0, count: 32))
        var delivered = false
        cache.request(item, load: { Thread.sleep(forTimeInterval: 0.05); return text }, completion: { _ in delivered = true })
        cache.clear()
        try await Task.sleep(nanoseconds: 120_000_000)
        try check(!delivered, "locking cancels thumbnail callbacks and discards late decoded images")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(image.bitmapData!, 140, image.bytesPerRow * image.pixelsHigh)
        let png = image.representation(using: .png, properties: [:])!
        let fixture = root.deletingLastPathComponent().appendingPathComponent("Thumbnail rename fixture.png")
        try png.write(to: fixture)
        model.unlock(passcode: "browser test phrase")
        try await wait(model)
        model.importFiles([fixture])
        try await wait(model)
        guard let original = model.manifest.items.first(where: { $0.name == fixture.lastPathComponent }),
              let storage = model.storage, let header = model.header else {
            throw VaultError.message("Missing thumbnail rename fixture.")
        }
        var renamed = original
        renamed.name = "Thumbnail rename fixture"
        let vaultKey = try storage.passcodeKey("browser test phrase", header: header)
        var manifest = model.manifest
        manifest.items[manifest.items.firstIndex(where: { $0.id == renamed.id })!] = renamed
        try storage.saveManifest(manifest, vaultID: header.id, key: vaultKey)
        model.lock()
        model.unlock(passcode: "browser test phrase")
        try await wait(model)
        guard let reopened = model.manifest.items.first(where: { $0.id == renamed.id }) else {
            throw VaultError.message("Missing renamed thumbnail fixture.")
        }
        let afterRename: NSImage? = await withCheckedContinuation { continuation in
            model.requestThumbnail(reopened) { continuation.resume(returning: $0) }
        }
        try check(reopened.name == renamed.name && afterRename != nil, "an image renamed without an extension regenerates its thumbnail after relocking")
        let shareBase = root.deletingLastPathComponent().appendingPathComponent("renamed-image-share")
        let share = try VaultShareFiles.prepare([reopened], storage: storage, manifest: model.manifest,
                                               vaultID: header.id, key: vaultKey, temporaryBase: shareBase)
        let sharedImage = share.urls[0]
        let sharedBytes = try Data(contentsOf: sharedImage)
        try check(sharedImage.lastPathComponent == reopened.name + ".png" &&
                  UTType(filenameExtension: sharedImage.pathExtension) == .png &&
                  sharedBytes == png,
                  "sharing an extensionless PNG restores the PNG extension and preserves the image bytes")
        let suggestedName = try storage.suggestedExportName(reopened, vaultID: header.id, key: vaultKey)
        try check(suggestedName == reopened.name + ".png", "the Save panel suggests the restored image extension")
        let exportRoot = root.deletingLastPathComponent().appendingPathComponent("renamed-image-export")
        try VaultStorage.directory(exportRoot)
        let preferred = exportRoot.appendingPathComponent(reopened.name)
        let exported = try storage.export(reopened, to: preferred, manifest: model.manifest, vaultID: header.id, key: vaultKey)
        let exportedBytes = try Data(contentsOf: exported)
        try check(exported.lastPathComponent == suggestedName && exportedBytes == png, "export restores the PNG extension and preserves the original bytes")
        try rejects("a corrected export filename never overwrites an existing PNG") {
            try storage.export(reopened, to: preferred, manifest: model.manifest, vaultID: header.id, key: vaultKey)
        }
        let duplicate = try storage.export(reopened, to: preferred, manifest: model.manifest, vaultID: header.id, key: vaultKey, uniquingName: true)
        try check(duplicate.lastPathComponent == reopened.name + " (2).png", "batch export puts duplicate numbering before the corrected extension")
        let folder = VaultItem(id: UUID(), parent: nil, name: "Images", isFolder: true, size: 0, created: Date(), modified: Date(), digest: nil)
        var child = reopened
        child.parent = folder.id
        var folderManifest = VaultManifest()
        folderManifest.items = [folder, child]
        let exportedFolder = try storage.export(folder, to: exportRoot.appendingPathComponent(folder.name),
                                                manifest: folderManifest, vaultID: header.id, key: vaultKey)
        try check(try Data(contentsOf: exportedFolder.appendingPathComponent(suggestedName)) == png,
                  "folder export restores image extensions inside the folder")

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
        let stagedBytes = try Data(contentsOf: files!.urls[0])
        try check(files!.urls[0].lastPathComponent == "share.txt" && stagedBytes == bytes,
                  "sharing stages a verified readable copy with the existing filename in an isolated temporary folder")
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
            try check(collection.registeredDraggedTypes == [FileCollectionView.vaultDragType] && scroll.registeredDraggedTypes.isEmpty,
                      "the file canvas accepts internal moves and delegates screenshot imports to its containing drop region")
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
        let pathFolder = VaultItem(id: UUID(), parent: nil, name: "Path drop fixture", isFolder: true, size: 0, created: Date(), modified: Date(), digest: nil)
        model.manifest.items.append(pathFolder)
        try model.storage!.saveManifest(model.manifest, vaultID: savedID, key: key)
        let pathFiles = Set(model.visible.filter { !$0.isFolder }.map(\.id))
        model.internalDragIDs = pathFiles
        try check(model.dropSelection(in: pathFolder.id), "a path folder accepts an internal selection")
        try await wait(model)
        model.navigate(pathFolder.id)
        model.internalDragIDs = pathFiles
        try check(model.dropSelection(in: nil), "the All files breadcrumb accepts a selection from a nested folder")
        try await wait(model)
        try check(model.manifest.items.filter { pathFiles.contains($0.id) }.allSatisfy { $0.parent == nil },
                  "dropping on All files moves every selected item to the vault root")
        model.internalDragIDs = [pathFolder.id]
        try check(!model.canDropSelection(in: pathFolder.id), "path drops reject moving a folder inside itself")
        model.internalDragIDs = []
        model.navigate(nil)
        let droppedIDs = Set(model.visible.map(\.id))
        model.selectAll()
        model.deleteSelection(confirm: false)
        try await wait(model)
        try check(model.visible.isEmpty && Set(model.manifest.recentlyDeleted.map(\.id)) == droppedIDs,
                  "dropping a selection in Recently Deleted moves all selected files without a confirmation dialog")
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

private final class FixtureDropPromise: DroppedFilePromise {
    enum Behavior { case success, failure, never, outside(URL) }
    let fileNames: [String]
    let data: Data
    let behavior: Behavior
    init(names: [String], data: Data, behavior: Behavior = .success) { fileNames = names; self.data = data; self.behavior = behavior }
    func receive(into folder: URL, queue: OperationQueue, completion: @escaping (URL, Error?) -> Void) {
        if case .never = behavior { return }
        for name in fileNames {
            queue.addOperation {
                let url = folder.appendingPathComponent(name)
                do {
                    if case .failure = self.behavior { throw VaultError.message("Generated promise failure") }
                    if case let .outside(other) = self.behavior { completion(other, nil); return }
                    try self.data.write(to: url)
                    completion(url, nil)
                } catch { completion(url, error) }
            }
        }
    }
}
private final class FixtureNativePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let data: Data
    init(data: Data) { self.data = data }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Native screenshot.png" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

private final class OCRFixtureProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [String] = []
    func add(_ page: Int, _ total: Int) { lock.lock(); defer { lock.unlock() }; progress.append("\(page)/\(total)") }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return progress }
}

extension StorageTests {
    static func portableVaultChecks(root: URL) async throws {
        try VaultStorage.directory(root)
        let source = try VaultStorage(root: root.appendingPathComponent("source"))
        let target = try VaultStorage(root: root.appendingPathComponent("target"))
        let (original, originalKey) = try source.create(name: "Portable fixture", passcode: "original fixture password", mac: false)
        let input = root.appendingPathComponent("Original folder")
        try VaultStorage.directory(input.appendingPathComponent("Empty folder"))
        let bytes = Data((0..<(VaultCrypto.chunkSize + 119)).map { UInt8($0 % 251) })
        try bytes.write(to: input.appendingPathComponent("multi.bin"))
        let secret = Data("PORTABLE-PRIVATE-FIXTURE-MARKER".utf8)
        try secret.write(to: input.appendingPathComponent("private-name.txt"))
        try Data().write(to: input.appendingPathComponent("empty.bin"))
        let removed = root.appendingPathComponent("excluded.txt")
        try Data("Recently deleted fixture".utf8).write(to: removed)
        let imported = try source.importSources([input, removed], parent: nil, manifest: VaultManifest(), vaultID: original.id, key: originalKey)
        let deleted = imported.manifest.items.first { $0.name == "excluded.txt" }!
        let before = try source.trashItems([deleted], manifest: imported.manifest, vaultID: original.id, key: originalKey)
        let file = root.appendingPathComponent("Fixture.harb")
        let receipt = try PortableVault.export(storage: source, header: original, key: originalKey, to: file)
        let package = try Data(contentsOf: file)
        try check(package.prefix(8) == Data("HARBPK02".utf8), "portable export uses the padded version-2 envelope")
        try check(package.range(of: secret) == nil && package.range(of: Data("private-name.txt".utf8)) == nil,
                  "portable vault encrypts filenames and file contents")
        try check(package.range(of: Data(receipt.sharingKey.utf8)) == nil && package.range(of: VaultCrypto.keyData(originalKey)) == nil,
                  "portable file excludes the sharing key and the source vault key")
        try check(try VaultCrypto.keyData(PortableVault.parseKey(receipt.sharingKey)) != VaultCrypto.keyData(originalKey),
                  "portable exports use a fresh independent encryption key")
        try rejects("incomplete portable keys are rejected") { _ = try PortableVault.parseKey("HARB-123") }
        try rejects("exporting a portable vault never overwrites a file") {
            _ = try PortableVault.export(storage: source, header: original, key: originalKey, to: file)
        }
        let cleanTarget = try target.headers().count
        try rejects("a wrong sharing key cannot import the portable vault") {
            _ = try PortableVault.importVault(from: file, sharingKey: String(repeating: "0", count: 64), name: "", passcode: "recipient fixture password", mac: false, into: target)
        }
        try check(try target.headers().count == cleanTarget, "wrong-key imports leave no registered vault")
        let (copy, copyKey, manifest) = try PortableVault.importVault(from: file, sharingKey: receipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target)
        try check(copy.id != original.id && copy.name == original.name && copy.macUnlock == nil,
                  "import creates a new local vault identity and preserves the portable name")
        try check(VaultCrypto.keyData(copyKey) != VaultCrypto.keyData(originalKey) &&
                  VaultCrypto.keyData(copyKey) != (try VaultCrypto.keyData(PortableVault.parseKey(receipt.sharingKey))),
                  "the imported vault uses its own fresh encryption key")
        let reopenedKey = try target.passcodeKey("recipient fixture password", header: copy)
        try check(VaultCrypto.keyData(reopenedKey) == VaultCrypto.keyData(copyKey), "the recipient password unlocks the local copy")
        try rejects("the sender password cannot unlock the recipient copy") { _ = try target.passcodeKey("original fixture password", header: copy) }
        try check(manifest.items == before.items.filter { !$0.isDeleted } && manifest.recentlyDeleted.isEmpty,
                  "portable export preserves active folder structure and excludes Recently Deleted")
        for entry in manifest.items where !entry.isFolder {
            let expected = try source.preview(entry, vaultID: original.id, key: originalKey)
            try check(try target.preview(entry, vaultID: copy.id, key: reopenedKey) == expected,
                      "portable roundtrip preserves verified bytes for " + entry.name)
        }
        try check(try source.loadManifest(vaultID: original.id, key: originalKey).items == before.items,
                  "export leaves the source vault and Recently Deleted intact")
        try rejects("replayed portable vaults require explicit confirmation") {
            _ = try PortableVault.importVault(from: file, sharingKey: receipt.sharingKey, name: "Second copy", passcode: "another recipient password", mac: false, into: target)
        }
        let (second, _, _) = try PortableVault.importVault(from: file, sharingKey: receipt.sharingKey, name: "Second copy", passcode: "another recipient password", mac: false, into: target, allowPreviouslyImported: true)
        try check(second.id != copy.id, "importing the same portable vault twice creates independent vaults")
        var broken = package
        broken[broken.count - 1] ^= 1
        let tampered = root.appendingPathComponent("Damaged.harb")
        try broken.write(to: tampered)
        try rejects("tampered portable ciphertext cannot be imported") {
            _ = try PortableVault.importVault(from: tampered, sharingKey: receipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target)
        }
        try check(try target.headers().count == 2, "a failed import never registers a partial vault")
        let remnants = try FileManager.default.contentsOfDirectory(atPath: target.root.path)
        try check(!remnants.contains { $0.hasPrefix(".harb-import-") }, "a failed import removes its encrypted staging directory")
        for data in [Data(package.dropLast()), package + Data([0])] {
            try data.write(to: tampered)
            try rejects("truncated or appended portable data is rejected") {
                _ = try PortableVault.importVault(from: tampered, sharingKey: receipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target)
            }
        }
        let (emptyHeader, emptyKey) = try source.create(name: "Empty portable", passcode: "empty fixture password", mac: false)
        let emptyURL = root.appendingPathComponent("Empty.harb")
        let emptyReceipt = try PortableVault.export(storage: source, header: emptyHeader, key: emptyKey, to: emptyURL)
        let (_, _, emptyManifest) = try PortableVault.importVault(from: emptyURL, sharingKey: emptyReceipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target)
        try check(emptyManifest.items.isEmpty, "empty vaults can be exported and imported")
        let publicURL = root.appendingPathComponent("Public.harb")
        let publicReceipt = try PortableVault.export(storage: source, header: original, key: originalKey, to: publicURL, publiclyReadable: true)
        try check(publicReceipt.isPublic && publicReceipt.sharingKey.isEmpty && (try PortableVault.isPublic(publicURL)), "public exports are explicitly marked and require no separate key")
        try check(try !PortableVault.isPublic(file), "private exports keep their private format by default")
        let (publicHeader, publicKey, publicManifest) = try PortableVault.importVault(from: publicURL, sharingKey: "", name: "Public import fixture", passcode: "public import fixture password", mac: false, into: target)
        try check(publicManifest.items == before.items.filter { !$0.isDeleted }, "public copies preserve active folders and files while excluding trash")
        for entry in publicManifest.items where !entry.isFolder {
            try check(try target.preview(entry, vaultID: publicHeader.id, key: publicKey) == source.preview(entry, vaultID: original.id, key: originalKey), "public copy verifies the original bytes for " + entry.name)
        }
        try rejects("imported public copies are protected by their chosen local password") { _ = try target.passcodeKey("", header: publicHeader) }
        try check(try source.loadManifest(vaultID: original.id, key: originalKey).items == before.items, "creating a public copy leaves the original private vault unchanged")
        var damagedPublic = try Data(contentsOf: publicURL)
        damagedPublic[damagedPublic.count - 1] ^= 1
        let brokenPublicURL = root.appendingPathComponent("Broken public.harb")
        try damagedPublic.write(to: brokenPublicURL)
        try rejects("damaged public copies are rejected") {
            _ = try PortableVault.importVault(from: brokenPublicURL, sharingKey: "", name: "", passcode: "public import fixture password", mac: false, into: target, allowPreviouslyImported: true)
        }
        let clearKey = try PortableVault.parseKey(receipt.sharingKey)
        let inner = root.appendingPathComponent("Unwrapped encrypted archive")
        try PortableEnvelope.unwrap(file, to: inner, key: clearKey)
        try check(try Data(contentsOf: inner).prefix(8) == Data("HARBPK01".utf8), "version 2 hides all legacy framing inside the encrypted envelope")
        try check(package.range(of: Data("HARBOR01".utf8)) == nil, "portable file headers are hidden by the outer envelope")
        for position in [8, 40, 48, 48 + 1024 * 1024 + 27] {
            var changed = package
            changed[position] ^= 1
            let hostile = root.appendingPathComponent("Envelope tamper.harb")
            try changed.write(to: hostile)
            try rejects("outer header and record tampering is rejected at byte \(position)") {
                _ = try PortableVault.importVault(from: hostile, sharingKey: receipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target, allowPreviouslyImported: true)
            }
        }
        let smallURL = root.appendingPathComponent("Small.harb")
        let smallReceipt = try PortableVault.export(storage: source, header: emptyHeader, key: emptyKey, to: smallURL)
        try check(try Data(contentsOf: smallURL).count == Data(contentsOf: emptyURL).count, "padding conceals exact sizes of small portable archives")
        let protectedKeyURL = root.appendingPathComponent("Key.harbkey")
        try ProtectedSharingKey.save(smallReceipt.sharingKey, password: "protected key password", to: protectedKeyURL)
        let protectedBytes = try Data(contentsOf: protectedKeyURL)
        try check(protectedBytes.range(of: Data(smallReceipt.sharingKey.utf8)) == nil, "saved sharing keys are encrypted on disk")
        try check(try ProtectedSharingKey.load(from: protectedKeyURL, password: "protected key password") == smallReceipt.sharingKey, "saved keys unlock with their own password")
        try rejects("wrong saved-key passwords are rejected") { _ = try ProtectedSharingKey.load(from: protectedKeyURL, password: "wrong key password") }
        var hostileManifest = VaultManifest()
        hostileManifest.items = [VaultItem(id: UUID(), parent: nil, name: "Huge folder", isFolder: true, size: Int64.max, created: Date(), modified: Date(), digest: nil)]
        try rejects("hostile folder sizes cannot reach the status-bar accumulator") { try target.validate(hostileManifest) }
        var alteredHeader = copy
        alteredHeader.name = "Forged name"
        try rejects("local header names are authenticated") { _ = try target.passcodeKey("recipient fixture password", header: alteredHeader) }
        alteredHeader = copy
        alteredHeader.version = 1; alteredHeader.authenticationTag = nil
        try rejects("new headers cannot be downgraded to bypass authentication") { _ = try target.passcodeKey("recipient fixture password", header: alteredHeader) }
        let legacyURL = root.appendingPathComponent("Legacy.harb")
        let legacyReceipt = try PortableVault.exportLegacy(storage: source, header: emptyHeader, key: emptyKey, to: legacyURL)
        var legacy = try Data(contentsOf: legacyURL)
        let legacyID = String(data: legacy.subdata(in: 8..<44), encoding: .utf8)!
        let oldLength = legacy.subdata(in: 44..<52).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let legacyKey = try PortableVault.parseKey(legacyReceipt.sharingKey)
        let catalogData = try VaultCrypto.open(legacy.subdata(in: 52..<52 + Int(oldLength)), key: legacyKey, context: "harb/catalog/" + legacyID)
        var catalogObject = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]
        catalogObject["version"] = 1
        catalogObject.removeValue(forKey: "sourceID"); catalogObject.removeValue(forKey: "exportedAt")
        let legacyMetadata = try VaultCrypto.seal(JSONSerialization.data(withJSONObject: catalogObject), key: legacyKey, context: "harb/catalog/" + legacyID)
        var legacyLength = UInt64(legacyMetadata.count).bigEndian
        legacy = Data("HARBPK01".utf8) + Data(legacyID.utf8) + withUnsafeBytes(of: &legacyLength) { Data($0) } + legacyMetadata
        try legacy.write(to: legacyURL)
        let (_, _, legacyManifest) = try PortableVault.importVault(from: legacyURL, sharingKey: legacyReceipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target)
        try check(legacyManifest.items.isEmpty, "original version-1 portable vaults remain importable")
        let invalidFolder = VaultItem(id: UUID(), parent: nil, name: "Invalid size", isFolder: true, size: Int64.max, created: Date(), modified: Date(), digest: nil)
        var forgedManifest = VaultManifest()
        forgedManifest.items = [invalidFolder]
        catalogObject["manifest"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(forgedManifest))
        let forgedMetadata = try VaultCrypto.seal(JSONSerialization.data(withJSONObject: catalogObject), key: legacyKey, context: "harb/catalog/" + legacyID)
        var forgedLength = UInt64(forgedMetadata.count).bigEndian
        let forged = Data("HARBPK01".utf8) + Data(legacyID.utf8) + withUnsafeBytes(of: &forgedLength) { Data($0) } + forgedMetadata
        let forgedURL = root.appendingPathComponent("Hostile authenticated metadata.harb")
        try forged.write(to: forgedURL)
        try rejects("a malicious sender's authenticated folder sizes are rejected during import") {
            _ = try PortableVault.importVault(from: forgedURL, sharingKey: legacyReceipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target, allowPreviouslyImported: true)
        }
        let oversized = root.appendingPathComponent("Oversized metadata")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let hugeHandle = try FileHandle(forWritingTo: oversized)
        try hugeHandle.truncate(atOffset: 8192)
        try hugeHandle.close()
        try rejects("bounded reads reject oversized metadata before decoding") { _ = try SecurityIO.read(oversized, maximum: 4096) }
        let symlink = root.appendingPathComponent("Metadata link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: oversized)
        try rejects("security reads reject symbolic links") { _ = try SecurityIO.open(symlink) }
        let countBeforeCancel = try target.headers().count
        let cancelledImport = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PortableVault.importVault(from: file, sharingKey: receipt.sharingKey, name: "", passcode: "recipient fixture password", mac: false, into: target)
        }
        do {
            _ = try await cancelledImport.value
            throw VaultError.message("Cancelled import unexpectedly completed.")
        } catch is CancellationError {
            try check(try target.headers().count == countBeforeCancel, "cancelled imports leave existing vaults intact and register no partial copy")
        }
        let cancelledURL = root.appendingPathComponent("Cancelled.harb")
        let cancelledExport = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PortableVault.export(storage: source, header: original, key: originalKey, to: cancelledURL)
        }
        do {
            _ = try await cancelledExport.value
            throw VaultError.message("Cancelled export unexpectedly completed.")
        } catch is CancellationError {
            try check(!FileManager.default.fileExists(atPath: cancelledURL.path), "cancelled exports leave no partial .harb file")
        }
    }
}

extension StorageTests {
    @MainActor static func secretClipboardChecks() async throws {
        let board = NSPasteboard(name: .init("HarborSecretFixture-" + UUID().uuidString))
        defer { SecretClipboard.clearIfOwned(); board.clearContents() }
        SecretClipboard.copy("disposable sharing key", to: board, expiresAfter: 0.04)
        try check(board.string(forType: .string) == "disposable sharing key" &&
                  board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true,
                  "sharing-key copies use concealed clipboard hints")
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(board.string(forType: .string) == nil, "sharing-key clipboard entries expire automatically")
        SecretClipboard.copy("another fixture key", to: board, expiresAfter: 60)
        board.clearContents()
        board.setString("new unrelated clipboard content", forType: .string)
        SecretClipboard.clearIfOwned()
        try check(board.string(forType: .string) == "new unrelated clipboard content",
                  "secret cleanup preserves newer clipboard content")
    }

    static func keychainChecks() throws {
        let id = UUID()
        let sourceID = UUID()
        defer {
            for (service, account) in [("com.harborvault.local-state.v1", id), ("com.harborvault.portable-history.v1", sourceID)] {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account.uuidString,
                    kSecAttrSynchronizable as String: false]
                SecItemDelete(query as CFDictionary)
            }
        }
        let first = Data(repeating: 1, count: 32)
        let second = Data(repeating: 2, count: 32)
        let third = Data(repeating: 3, count: 32)
        try LocalVaultHistory.prepare(previous: nil, next: first, id: id)
        try LocalVaultHistory.verify(first, id: id)
        try LocalVaultHistory.prepare(previous: first, next: second, id: id)
        try LocalVaultHistory.verify(second, id: id)
        try rejects("Keychain checkpoints detect a restored older metadata state") { try LocalVaultHistory.verify(first, id: id) }
        try LocalVaultHistory.prepare(previous: second, next: third, id: id)
        try LocalVaultHistory.verify(second, id: id)
        try rejects("an interrupted metadata write recovers the observed old state") { try LocalVaultHistory.verify(third, id: id) }
        let date = Date()
        try PortableHistory.record(date, for: sourceID)
        try PortableHistory.record(date.addingTimeInterval(-10), for: sourceID)
        try check(try PortableHistory.latest(for: sourceID) == date, "portable history cannot move its known export date backwards")
    }
}
