import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

protocol DroppedFilePromise: AnyObject {
    var fileNames: [String] { get }
    func receive(into folder: URL, queue: OperationQueue, completion: @escaping (URL, Error?) -> Void)
}
final class NativeDroppedFilePromise: DroppedFilePromise {
    let receiver: NSFilePromiseReceiver
    init(_ receiver: NSFilePromiseReceiver) { self.receiver = receiver }
    var fileNames: [String] {
        if Thread.isMainThread { return receiver.fileNames }
        return DispatchQueue.main.sync { receiver.fileNames }
    }
    func receive(into folder: URL, queue: OperationQueue, completion: @escaping (URL, Error?) -> Void) {
        let begin = { self.receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue, reader: completion) }
        // AppKit resolves pasteboard promises on the main thread. The supplied
        // operation queue still keeps file delivery/copying off the UI thread.
        if Thread.isMainThread { begin() } else { DispatchQueue.main.sync(execute: begin) }
    }
}

enum FileDropSource {
    case file(URL)
    case image(Data)
    case promise(DroppedFilePromise)
}

final class FileDropRequest: @unchecked Sendable {
    static let imageTypes: [NSPasteboard.PasteboardType] = [UTType.png, .tiff, .jpeg, .heic, .heif, .gif, .bmp].map { .init($0.identifier) }
    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + imageTypes + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
    }
    let sources: [FileDropSource]
    init(sources: [FileDropSource]) { self.sources = sources }
    static func supports(_ pasteboard: NSPasteboard) -> Bool { pasteboard.availableType(from: registeredTypes) != nil }
    // Read only the pasteboard supplied by this drop, never the general clipboard.
    static func read(_ pasteboard: NSPasteboard) throws -> FileDropRequest {
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        var sources: [FileDropSource] = receivers.map { .promise(NativeDroppedFilePromise($0)) }
        for item in pasteboard.pasteboardItems ?? [] {
            if !Set(item.types).isDisjoint(with: promiseTypes) {
                guard !receivers.isEmpty else { throw VaultError.message("The source app could not provide its promised file. Try dragging it again.") }
                continue // Use the promised original, not a duplicate preview representation.
            }
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                sources.append(.file(url)); continue
            }
            if let type = imageTypes.first(where: { item.types.contains($0) }), let data = item.data(forType: type) {
                sources.append(.image(data)); continue
            }
            throw VaultError.message("This dragged item does not contain a local file or a supported image.")
        }
        guard !sources.isEmpty else { throw VaultError.message("No files or images were available in this drop.") }
        return FileDropRequest(sources: sources)
    }

    func prepare(temporaryBase: URL = FileDropStaging.base, promiseTimeout: TimeInterval = 45) throws -> FileDropStaging {
        let staging = try FileDropStaging(base: temporaryBase)
        var complete = false
        defer { if !complete { staging.remove() } }
        let queue = OperationQueue(); queue.name = "Harbor Vault screenshot delivery"; queue.maxConcurrentOperationCount = 1
        // Start all promises against the same destination, as required by AppKit.
        var pending: [PendingDropPromise] = []
        for source in sources {
            try Task.checkCancellation()
            switch source {
            case let .file(url):
                guard url.isFileURL else { throw VaultError.message("Only local files can be imported.") }
                staging.append(url, original: true)
            case let .image(data): try staging.addImage(data)
            case let .promise(promise):
                let receipt = PendingDropPromise(); pending.append(receipt)
                promise.receive(into: staging.promises, queue: queue) { url, error in
                    do {
                        if let error { throw error }
                        try staging.capture(url)
                        receipt.record(nil)
                    } catch { receipt.record(error) }
                }
                // Names are populated when receivePromisedFiles is called. Unlike
                // fileTypes, this also handles multiple files of the same type.
                receipt.expect(max(1, promise.fileNames.count))
            }
        }
        let deadline = Date().addingTimeInterval(promiseTimeout)
        for receipt in pending { try receipt.wait(until: deadline) }
        try Task.checkCancellation()
        guard !staging.urls.isEmpty else { throw VaultError.message("The source app did not deliver a file.") }
        complete = true
        return staging
    }
}

private final class PendingDropPromise: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var expected: Int?
    private var received = 0
    private var failure: Error?
    private var finished = false
    func expect(_ count: Int) { lock.lock(); defer { lock.unlock() }; expected = count; finishIfReady() }
    func record(_ error: Error?) { lock.lock(); defer { lock.unlock() }; received += 1; if failure == nil { failure = error }; finishIfReady() }
    private func finishIfReady() {
        if !finished, let expected, received >= expected { finished = true; done.signal() }
    }
    func wait(until deadline: Date) throws {
        while done.wait(timeout: .now() + 0.025) == .timedOut {
            try Task.checkCancellation()
            guard Date() < deadline else { throw VaultError.message("The screenshot or file did not finish arriving. Try the drop again, or save it and import the saved copy.") }
        }
        lock.lock(); let error = failure; lock.unlock()
        if let error { throw error }
    }
}

final class FileDropStaging: @unchecked Sendable {
    static var base: URL { FileManager.default.temporaryDirectory.appendingPathComponent("HarborVaultImports.noindex", isDirectory: true) }
    let folder: URL
    let promises: URL
    private let lock = NSLock()
    private var closed = false
    private var values: [URL] = []
    private var originals: Set<URL> = []
    init(base: URL) throws {
        try VaultStorage.directory(base)
        folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        promises = folder.appendingPathComponent("promises", isDirectory: true)
        do { try VaultStorage.directory(folder); try VaultStorage.directory(promises) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        var privateFolder = folder
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try privateFolder.setResourceValues(attributes)
    }
    deinit { remove() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
    var originalURLs: Set<URL> { lock.lock(); defer { lock.unlock() }; return originals }
    func append(_ url: URL, original: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        values.append(url)
        if original { originals.insert(url.standardizedFileURL) }
    }
    func addImage(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 256 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0, let identifier = CGImageSourceGetType(image),
              let ext = UTType(identifier as String)?.preferredFilenameExtension else { throw VaultError.message("The dragged image could not be read. Try dragging it again.") }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try VaultStorage.directory(destination)
        let url = destination.appendingPathComponent("Screenshot." + ext)
        try VaultStorage.atomic(data, to: url) // Preserve the original image bytes.
        values.append(url)
    }
    func capture(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { try? FileManager.default.removeItem(at: folder); throw CancellationError() }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let allowed = promises.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.isFileURL, resolved.hasPrefix(allowed) else { throw VaultError.message("The source app delivered a file outside the drop destination.") }
        let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isRegularFileKey, .isDirectoryKey])
        guard attributes.isSymbolicLink != true, attributes.isAliasFile != true,
              attributes.isRegularFile == true || attributes.isDirectory == true else { throw VaultError.message("The source app delivered an invalid promised file.") }
        try VaultStorage.validName(url.lastPathComponent)
        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try VaultStorage.directory(destination)
        let copy = destination.appendingPathComponent(url.lastPathComponent)
        // Copy inside the receiver's coordinated-read callback; the source may
        // withdraw its representation as soon as that callback returns.
        try FileManager.default.copyItem(at: url, to: copy)
        try Self.protect(copy)
        values.append(copy)
        try? FileManager.default.removeItem(at: url)
    }
    private static func protect(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw VaultError.message("Promised symbolic links cannot be imported.") }
        try FileManager.default.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: url.path)
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try protect(child) }
        }
    }
    @discardableResult func remove() -> String? {
        lock.lock(); defer { lock.unlock() }
        closed = true
        var warning: String?
        if FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) }
            catch { warning = "Temporary readable import copies could not be removed. Reopen Harbor to retry cleanup." }
        }
        values = []; originals = []
        return warning
    }
    @discardableResult static func removeStaleCopies() -> String? {
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        do { try FileManager.default.removeItem(at: base); return nil }
        catch { return "Readable import copies from an earlier session could not be cleaned up." }
    }
}

struct NativeDropRegion<Content: View>: NSViewRepresentable {
    let model: AppModel
    @Binding var targeted: Bool
    @ViewBuilder let content: Content
    func makeNSView(context: Context) -> NativeDropContainer {
        let view = NativeDropContainer(); configure(view); return view
    }
    func updateNSView(_ view: NativeDropContainer, context: Context) { configure(view) }
    static func dismantleNSView(_ view: NativeDropContainer, coordinator: ()) {
        view.model = nil; view.targetChanged = nil; view.host.rootView = AnyView(EmptyView())
    }
    @MainActor private func configure(_ view: NativeDropContainer) {
        view.model = model
        view.targetChanged = { targeted = $0 }
        view.host.rootView = AnyView(content.environmentObject(model))
    }
}

@MainActor final class NativeDropContainer: NSView {
    weak var model: AppModel?
    var targetChanged: ((Bool) -> Void)?
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(FileDropRequest.registeredTypes)
        host.autoresizingMask = [.width, .height]; host.frame = bounds; addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); host.frame = bounds }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = model?.canImportDrop == true && sender.draggingSourceOperationMask.contains(.copy) && FileDropRequest.supports(sender.draggingPasteboard)
        targetChanged?(accepts)
        return accepts ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { targetChanged?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { updateDrop(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targetChanged?(false)
        guard let model, model.canImportDrop else { return false }
        do { model.importDrop(try FileDropRequest.read(sender.draggingPasteboard)); return true }
        catch { model.error = error.localizedDescription; return false }
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { targetChanged?(false) }
}
