import Foundation
import AppKit
import CryptoKit

final class VaultShareFiles: @unchecked Sendable {
    let folder: URL
    let urls: [URL]
    static var base: URL { FileManager.default.temporaryDirectory.appendingPathComponent("HarborVaultSharing.noindex", isDirectory: true) }
    init(folder: URL, urls: [URL]) { self.folder = folder; self.urls = urls }
    deinit { try? FileManager.default.removeItem(at: folder) }
    func remove() { try? FileManager.default.removeItem(at: folder) }
    static func prepare(_ requested: [VaultItem], storage: VaultStorage, manifest: VaultManifest, vaultID: UUID, key: SymmetricKey, temporaryBase: URL = base) throws -> VaultShareFiles {
        try VaultStorage.directory(temporaryBase)
        let folder = temporaryBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try VaultStorage.directory(folder)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        var urls: [URL] = []
        for request in requested {
            try Task.checkCancellation()
            guard let item = manifest.items.first(where: { $0.id == request.id }) else { throw VaultError.message("A selected item is no longer available. Sharing was cancelled.") }
            var name = item.name; var counter = 2
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                let ext = (item.name as NSString).pathExtension
                let base = ext.isEmpty ? item.name : (item.name as NSString).deletingPathExtension
                name = "\(base) (\(counter))" + (ext.isEmpty ? "" : "." + ext); counter += 1
            }
            let url = folder.appendingPathComponent(name)
            try storage.export(item, to: url, manifest: manifest, vaultID: vaultID, key: key)
            urls.append(url)
        }
        try Task.checkCancellation()
        completed = true
        return VaultShareFiles(folder: folder, urls: urls)
    }
    static func removeStaleCopies() {
        // Called only by the real app at startup, never by fixture tests.
        guard let children = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        for child in children where UUID(uuidString: child.lastPathComponent) != nil { try? FileManager.default.removeItem(at: child) }
    }
}

@MainActor final class VaultShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private var files: VaultShareFiles?
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?
    private var started = false
    private var cancelled = false
    private var completion: ((String) -> Void)?
    init(files: VaultShareFiles, completion: @escaping (String) -> Void) { self.files = files; self.completion = completion }
    func present() {
        guard !cancelled, let files, let view = NSApp.mainWindow?.contentView else { finish("Sharing cancelled."); return }
        let picker = NSSharingServicePicker(items: files.urls)
        self.picker = picker; picker.delegate = self
        let rect = NSRect(x: view.bounds.maxX - 90, y: view.isFlipped ? 80 : view.bounds.maxY - 80, width: 30, height: 30)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
    func cancelIfNotStarted() {
        guard !started else { return }
        cancelled = true; finish("Sharing cancelled.")
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else { finish("Sharing cancelled."); return }
        started = true; self.service = service
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish("Sharing completed. Temporary share copies removed.") }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finish("Sharing did not complete: " + error.localizedDescription) }
    private func finish(_ message: String) {
        guard files != nil else { return }
        files?.remove(); files = nil
        picker?.delegate = nil; picker = nil; service?.delegate = nil; service = nil
        let callback = completion; completion = nil; callback?(message)
    }
}

