import SwiftUI
import AppKit
import CryptoKit
import LocalAuthentication
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published var vaults: [VaultHeader] = []
    @Published var selectedVaultID: UUID?
    @Published var manifest = VaultManifest()
    @Published var unlocked = false
    @Published var busy = false
    @Published var activity = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var query = ""
    @Published var folderID: UUID?
    @Published var viewingRecentlyDeleted = false
    @Published var trashDateEdit: TrashDateRequest?
    @Published var restoreRequest: RestoreRequest?
    @Published var transferRequest: VaultTransferRequest?
    @Published var transferDestinationID: UUID?
    @Published var transferAuthenticatedAt: Date?
    private var transferPermit: VaultActionPermit?
    private var transferDestinationKey: SymmetricKey?
    private var transferContext: LAContext?
    private var lastTrashPurge = Date.distantPast
    @Published var selection: UUID?
    @Published var selectionIDs: Set<UUID> = []
    @Published var backHistory: [BrowserLocation] = []
    @Published var forwardHistory: [BrowserLocation] = []
    @Published var quickViewItem: VaultItem?
    @Published var quickViewItems: [VaultItem] = []
    @Published var quickViewIsGroup = false
    @Published var previewZoom: Double = 1
    @Published var quickViewError: String?
    @Published var quickViewLoading = false
    @Published var viewerLocked = false
    @Published var viewerAuthenticating = false
    @Published var viewerAuthError: String?
    private var viewerAuthContext: LAContext?
    private var viewerAuthJob: Task<Void, Error>?
    private var viewerAuthToken = UUID()
    @Published var smallPreviewItem: VaultItem?
    @Published var smallPreview: PreviewContent?
    @Published var smallPreviewLoading = false
    @Published var smallPreviewError: String?
    private var smallPreviewController: SmallPreviewController?
    private var smallPreviewJob: Task<Data, Error>?
    private var smallPreviewToken = UUID()
    @Published var thumbnailSize = max(80, min(224, UserDefaults.standard.double(forKey: "thumbnailSize") == 0 ? 128 : UserDefaults.standard.double(forKey: "thumbnailSize"))) {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize") }
    }
    let thumbnails = ThumbnailCache()
    private var selectionAnchor: UUID?
    private var quickViewController: QuickViewController?
    private var previewJob: Task<Data, Error>?
    private var previewToken = UUID()
    @Published var showCreate = false
    @Published var showPasscodeSettings = false
    @Published var showSettings = false
    @Published var protectedAction: VaultActionRequest?
    @Published var actionAuthenticatedAt: Date?
    private var actionPermit: VaultActionPermit?
    private var actionKey: SymmetricKey?
    private var shareSession: VaultShareSession?
    @Published var importResult: ImportResult?
    @Published var preview: PreviewContent?
    @Published var idleMinutes = UserDefaults.standard.integer(forKey: "idleMinutes") == 0 ? 5 : UserDefaults.standard.integer(forKey: "idleMinutes")
    @Published var grid = UserDefaults.standard.bool(forKey: "gridView") {
        didSet { UserDefaults.standard.set(grid, forKey: "gridView") }
    }
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "light" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    @Published var textSize = UserDefaults.standard.string(forKey: "textSize") ?? "standard" {
        didSet { UserDefaults.standard.set(textSize, forKey: "textSize") }
    }
    @Published var density = UserDefaults.standard.string(forKey: "density") ?? "comfortable" {
        didSet { UserDefaults.standard.set(density, forKey: "density") }
    }
    var textScale: CGFloat { textSize == "large" ? 1.14 : textSize == "small" ? 0.92 : 1 }
    let storage: VaultStorage?
    private var key: SymmetricKey?
    private var generation = UUID()
    private var cancelOperation: (() -> Void)?
    private var authContext: LAContext?
    private var lastActivity = Date()
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var timer: Timer?

    init(root: URL? = nil) {
        do {
            storage = try VaultStorage(root: root ?? VaultStorage.defaultRoot)
            if root == nil { VaultShareFiles.removeStaleCopies() }
        }
        catch { storage = nil; self.error = error.localizedDescription }
        reload()
        if storage != nil, vaults.isEmpty { showCreate = true }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.closeSmallPreview() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.lastActivity = Date() }; return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkIdle() } }
    }
    var header: VaultHeader? { vaults.first { $0.id == selectedVaultID } }
    var selectedItem: VaultItem? { manifest.items.first { $0.id == selection } }
    var selectedItems: [VaultItem] { visible.filter { selectionIDs.contains($0.id) } }
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var visible: [VaultItem] {
        let candidates = viewingRecentlyDeleted ? manifest.recentlyDeleted : manifest.items.filter { !$0.isDeleted }
        return candidates.filter { query.isEmpty ? (viewingRecentlyDeleted || $0.parent == folderID) : $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    var fileCount: Int { manifest.items.filter { !$0.isFolder && !$0.isDeleted }.count }
    var totalBytes: Int64 { manifest.items.filter { !$0.isDeleted }.reduce(0) { $0 + $1.size } }
    var trashCount: Int { manifest.recentlyDeleted.count }
    var trashBytes: Int64 { manifest.items.filter(\.isDeleted).reduce(0) { $0 + $1.size } }
    func childrenInPreview(of item: VaultItem) -> [VaultItem] {
        manifest.items.filter { $0.parent == item.id && $0.isDeleted == item.isDeleted && (!item.isDeleted || $0.trashRootID == item.trashRootID) }
    }
    var crumbs: [VaultItem] {
        var result: [VaultItem] = []; var id = folderID
        while let current = id, let entry = manifest.items.first(where: { $0.id == current }) { result.insert(entry, at: 0); id = entry.parent }
        return result
    }
    func reload() {
        guard let storage else { return }
        do { vaults = try storage.headers(); if selectedVaultID == nil { selectedVaultID = vaults.first?.id } }
        catch { self.error = "Couldn’t read vault storage: " + error.localizedDescription }
    }
    func choose(_ id: UUID) {
        if id == selectedVaultID { if viewingRecentlyDeleted { showRecentlyDeleted(false) }; return }
        lock(); selectedVaultID = id
    }
    func lock() {
        generation = UUID()
        cancelOperation?()
        authContext?.invalidate(); authContext = nil
        key = nil
        unlocked = false
        manifest = VaultManifest()
        query = ""; folderID = nil; selection = nil
        viewingRecentlyDeleted = false; trashDateEdit = nil; restoreRequest = nil; lastTrashPurge = .distantPast
        transferContext?.invalidate(); transferContext = nil
        transferRequest = nil; transferDestinationID = nil; transferAuthenticatedAt = nil; transferPermit = nil; transferDestinationKey = nil
        selectionIDs = []; selectionAnchor = nil
        backHistory = []; forwardHistory = []
        thumbnails.clear()
        closeQuickView()
        closeSmallPreview()
        protectedAction = nil; actionAuthenticatedAt = nil; actionPermit = nil; actionKey = nil
        shareSession?.cancelIfNotStarted()
        preview = nil; importResult = nil; showPasscodeSettings = false
        notice = nil; error = nil
    }
    func checkIdle(now: Date = Date()) {
        if let permit = transferPermit, !permit.isFresh(for: permit.vaultID, now: now) {
            transferPermit = nil; transferDestinationKey = nil; transferAuthenticatedAt = nil
        }
        if let permit = actionPermit, !permit.isFresh(for: permit.vaultID, now: now) {
            actionPermit = nil; actionKey = nil; actionAuthenticatedAt = nil
        }
        guard unlocked else { return }
        if now.timeIntervalSince(lastActivity) >= Double(idleMinutes * 60) { lock(); return }
        if now.timeIntervalSince(lastTrashPurge) >= 60 { purgeExpiredTrashIfNeeded(now: now) }
    }
    func setIdle(_ minutes: Int) { idleMinutes = minutes; UserDefaults.standard.set(minutes, forKey: "idleMinutes") }

    // All filesystem and cryptographic work runs off the UI thread. Cancel on lock,
    // and discard late results so they can never repopulate a locked window.
    private func run<T>(_ label: String, recordsActivity: Bool = true, operation: @escaping @Sendable () throws -> T, completion: @escaping (T) -> Void) {
        guard !busy else { return }
        error = nil; busy = true; activity = label
        if recordsActivity { lastActivity = Date() }
        let token = generation
        let job = Task.detached(priority: .userInitiated) { try operation() }
        cancelOperation = { job.cancel() }
        Task {
            do {
                let result = try await job.value
                busy = false; activity = ""; cancelOperation = nil
                if token == generation { if recordsActivity { lastActivity = Date() }; completion(result) }
            } catch {
                busy = false; activity = ""; cancelOperation = nil
                if token == generation && !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func create(name: String, passcode: String, mac: Bool) {
        guard let storage else { return }
        run("Creating encrypted vault…", operation: { try storage.create(name: name, passcode: passcode, mac: mac) }) { h, key in
            self.lock(); self.reload(); self.selectedVaultID = h.id
            self.key = key; self.unlocked = true; self.showCreate = false
        }
    }
    func unlock(passcode: String) {
        guard let storage, let header else { return }
        run("Unlocking vault…", operation: {
            let key = try storage.passcodeKey(passcode, header: header)
            return (key, try storage.loadManifest(vaultID: header.id, key: key))
        }) { key, manifest in self.key = key; self.manifest = manifest; self.unlocked = true; self.purgeExpiredTrashIfNeeded() }
    }
    func unlockMac() {
        guard let storage, let header, let mac = header.macUnlock else { return }
        let context = LAContext()
        context.localizedReason = "Unlock \(header.name) in Harbor Vault"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authContext = context
        run("Waiting for Mac authentication…", operation: {
            defer { context.invalidate() }
            let key = try VaultCrypto.macKey(mac, vaultID: header.id, context: context)
            return (key, try storage.loadManifest(vaultID: header.id, key: key))
        }) { key, manifest in
            context.invalidate(); self.authContext = nil
            self.key = key; self.manifest = manifest; self.unlocked = true
            self.purgeExpiredTrashIfNeeded()
        }
    }
    func changePasscode(_ passcode: String) {
        guard let storage, let header, let key else { return }
        run("Updating vault passcode…", operation: { try storage.changePasscode(passcode, header: header, key: key) }) { _ in
            self.reload(); self.showPasscodeSettings = false; self.notice = "Vault passcode updated."
        }
    }
    func toggleMacUnlock() {
        guard let storage, let header, let key else { return }
        let enable = header.macUnlock == nil
        run(enable ? "Enabling Mac unlock…" : "Disabling Mac unlock…", operation: {
            var updated = header
            updated.macUnlock = enable ? try VaultCrypto.makeMacUnlock(key: key, vaultID: header.id) : nil
            try storage.saveHeader(updated)
        }) { _ in self.reload(); self.notice = enable ? "Touch ID / Mac password enabled for this vault." : "This vault now requires its own passcode." }
    }
    private var location: BrowserLocation { BrowserLocation(folderID: folderID, query: query, selected: selectionIDs, lead: selection) }
    private func validLocation(_ location: BrowserLocation) -> Bool { location.folderID == nil || manifest.items.contains { $0.id == location.folderID && $0.isFolder && !$0.isDeleted } }
    private func restoreLocation(_ location: BrowserLocation) {
        closeQuickView(); closeSmallPreview(); folderID = location.folderID; query = location.query
        let visibleIDs = Set(visible.map(\.id))
        setSelection(location.selected.intersection(visibleIDs), lead: location.lead)
    }
    func navigate(_ id: UUID?) {
        guard unlocked, !viewingRecentlyDeleted, id == nil || manifest.items.contains(where: { $0.id == id && $0.isFolder && !$0.isDeleted }) else { return }
        guard id != folderID || !query.isEmpty else { return }
        backHistory.append(location); forwardHistory = []
        restoreLocation(BrowserLocation(folderID: id, query: ""))
    }
    func goBack() {
        while let previous = backHistory.popLast() {
            if validLocation(previous) { forwardHistory.append(location); restoreLocation(previous); return }
        }
    }
    func goForward() {
        while let next = forwardHistory.popLast() {
            if validLocation(next) { backHistory.append(location); restoreLocation(next); return }
        }
    }
    func goUp() {
        guard let folderID, let folder = manifest.items.first(where: { $0.id == folderID }) else { return }
        navigate(folder.parent)
    }
    func searchChanged() { clearSelection(); closeQuickView(); closeSmallPreview() }
    func clearSelection() { selectionIDs = []; selection = nil; selectionAnchor = nil }
    func setSelection(_ ids: Set<UUID>, lead: UUID? = nil, preserveAnchor: Bool = false) {
        selectionIDs = ids
        selection = lead.flatMap { ids.contains($0) ? $0 : nil } ?? visible.first { ids.contains($0.id) }?.id
        if !preserveAnchor { selectionAnchor = selection }
    }
    func select(_ id: UUID, shift: Bool = false, command: Bool = false) {
        let result = BrowserSelection.click(id, ordered: visible.map(\.id), selected: selectionIDs, anchor: selectionAnchor, shift: shift, command: command)
        selectionAnchor = result.anchor
        setSelection(result.ids, lead: result.lead, preserveAnchor: true)
        if quickViewItem != nil, let item = selectedItem { showQuickView(item) }
    }
    func selectAll() { setSelection(Set(visible.map(\.id))) }
    func moveSelection(by offset: Int, extend: Bool) {
        let items = visible
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection }
        let target = current.map { max(0, min(items.count - 1, $0 + offset)) } ?? (offset < 0 ? items.count - 1 : 0)
        select(items[target].id, shift: extend)
    }
    func requestThumbnail(_ item: VaultItem, completion: @escaping (NSImage?) -> Void) {
        guard unlocked, !item.isFolder, let storage, let header, let key else { completion(nil); return }
        thumbnails.request(item) { try storage.preview(item, vaultID: header.id, key: key) } completion: { [weak self] image in
            guard self?.unlocked == true else { return }; completion(image)
        }
    }
    func open(_ item: VaultItem) {
        if item.isFolder && !viewingRecentlyDeleted { navigate(item.id); return }
        if !selectionIDs.contains(item.id) { setSelection([item.id], lead: item.id) }
        showQuickView(item)
    }
    func toggleQuickView() {
        if quickViewItem != nil { closeQuickView() }
        else if let item = selectedItem { showQuickView(item, browseVisible: true) }
    }
    func showQuickView(_ item: VaultItem, browseVisible: Bool = false) {
        guard unlocked else { return }
        closeSmallPreview()
        if quickViewItem == nil {
            quickViewIsGroup = selectionIDs.count > 1
            quickViewItems = quickViewIsGroup ? selectedItems : browseVisible ? visible : [item]
        }
        if !quickViewItems.contains(where: { $0.id == item.id }) { quickViewItems = [item] }
        previewJob?.cancel(); previewToken = UUID()
        quickViewItem = item; preview = nil; quickViewError = nil; previewZoom = 1
        if quickViewController == nil { quickViewController = QuickViewController(model: self) }
        quickViewController?.show()
        guard !viewerLocked else { quickViewLoading = false; return }
        guard !item.isFolder, let storage, let header, let key else { quickViewLoading = false; return }
        quickViewLoading = true
        let token = previewToken; let session = generation
        let job = Task.detached(priority: .userInitiated) { try storage.preview(item, vaultID: header.id, key: key) }
        previewJob = job
        Task {
            do {
                let bytes = try await job.value
                guard self.unlocked, self.generation == session, self.previewToken == token else { return }
                self.preview = PreviewContent(item: item, data: bytes); self.quickViewLoading = false; self.previewJob = nil
            } catch {
                guard self.unlocked, self.generation == session, self.previewToken == token else { return }
                self.quickViewError = error.localizedDescription; self.quickViewLoading = false; self.previewJob = nil
            }
        }
    }
    var quickViewCandidates: [VaultItem] { quickViewItems }
    var quickViewPosition: String {
        let candidates = quickViewCandidates
        guard let index = candidates.firstIndex(where: { $0.id == quickViewItem?.id }) else { return "" }
        return "\(index + 1) of \(candidates.count)"
    }
    func quickViewStep(_ offset: Int) {
        let candidates = quickViewCandidates
        guard let index = candidates.firstIndex(where: { $0.id == quickViewItem?.id }), candidates.indices.contains(index + offset) else { return }
        let item = candidates[index + offset]
        if selectionIDs.count <= 1 { setSelection([item.id], lead: item.id) }
        else { selection = item.id }
        showQuickView(item)
    }
    func closeQuickView() {
        viewerAuthToken = UUID(); viewerAuthJob?.cancel(); viewerAuthJob = nil
        viewerAuthContext?.invalidate(); viewerAuthContext = nil
        viewerLocked = false; viewerAuthenticating = false; viewerAuthError = nil
        previewToken = UUID(); previewJob?.cancel(); previewJob = nil
        quickViewController?.close(); quickViewController = nil
        quickViewItem = nil; quickViewItems = []; quickViewIsGroup = false; preview = nil; quickViewError = nil; quickViewLoading = false; previewZoom = 1
    }
    func previewLostFocus() {
        guard quickViewItem != nil, !viewerAuthenticating else { return }
        previewToken = UUID(); previewJob?.cancel(); previewJob = nil
        preview = nil; quickViewLoading = false; quickViewError = nil
        viewerLocked = true; viewerAuthError = nil
    }
    func authenticateViewer(passcode: String? = nil, useMac: Bool = false) {
        guard unlocked, viewerLocked, !viewerAuthenticating, let storage, let header, let currentKey = key, quickViewItem != nil else { return }
        viewerAuthenticating = true; viewerAuthError = nil
        let context = LAContext(); context.localizedReason = "Unlock the private file viewer"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        viewerAuthContext = context; viewerAuthToken = UUID()
        let token = viewerAuthToken; let session = generation
        let job = Task.detached(priority: .userInitiated) {
            defer { context.invalidate() }
            let fresh = try storage.loadHeader(header.id)
            let verified: SymmetricKey
            if useMac {
                guard let mac = fresh.macUnlock else { throw VaultError.message("This vault requires its own passcode.") }
                verified = try VaultCrypto.macKey(mac, vaultID: fresh.id, context: context)
            } else {
                guard let passcode, !passcode.isEmpty else { throw VaultError.message("Enter this vault’s passcode.") }
                verified = try storage.passcodeKey(passcode, header: fresh)
            }
            guard VaultCrypto.keyData(verified) == VaultCrypto.keyData(currentKey) else { throw VaultError.message("Verification did not match this vault.") }
        }
        viewerAuthJob = job
        Task {
            do {
                try await job.value
                guard self.unlocked, self.generation == session, self.viewerAuthToken == token, let item = self.quickViewItem else { return }
                self.viewerAuthJob = nil; self.viewerAuthContext = nil
                // Keep the gate in place until this viewer is in front again.
                self.quickViewController?.show()
                self.viewerLocked = false; self.viewerAuthenticating = false
                if self.quickViewController != nil { self.showQuickView(item) }
            } catch {
                guard self.generation == session, self.viewerAuthToken == token else { return }
                self.viewerAuthJob = nil; self.viewerAuthContext = nil; self.viewerAuthenticating = false
                self.viewerAuthError = error.localizedDescription
            }
        }
    }
    func showSmallPreview(_ item: VaultItem, anchoredTo anchor: NSView) {
        guard unlocked, anchor.window != nil, !anchor.visibleRect.isEmpty else { return }
        closeSmallPreview()
        smallPreviewItem = item; smallPreviewError = nil
        let controller = SmallPreviewController(model: self)
        smallPreviewController = controller
        controller.show(anchoredTo: anchor)
        guard !item.isFolder, let storage, let header, let key else { return }
        smallPreviewLoading = true
        let token = smallPreviewToken; let session = generation
        let job = Task.detached(priority: .userInitiated) { try storage.preview(item, vaultID: header.id, key: key) }
        smallPreviewJob = job
        Task {
            do {
                let data = try await job.value
                guard self.unlocked, self.generation == session, self.smallPreviewToken == token else { return }
                self.smallPreview = PreviewContent(item: item, data: data); self.smallPreviewLoading = false; self.smallPreviewJob = nil
            } catch {
                guard self.unlocked, self.generation == session, self.smallPreviewToken == token else { return }
                self.smallPreviewError = error.localizedDescription; self.smallPreviewLoading = false; self.smallPreviewJob = nil
            }
        }
    }
    func closeSmallPreview() {
        smallPreviewToken = UUID(); smallPreviewJob?.cancel(); smallPreviewJob = nil
        smallPreviewController?.close(); smallPreviewController = nil
        smallPreviewItem = nil; smallPreview = nil; smallPreviewLoading = false; smallPreviewError = nil
    }
    func pickImport() {
        guard unlocked, !busy, !viewingRecentlyDeleted else { return }
        let panel = NSOpenPanel()
        panel.title = "Import into \(header?.name ?? "vault")"; panel.prompt = "Import"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { response in if response == .OK { Task { @MainActor in self.importFiles(panel.urls) } } }
    }
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, unlocked, !viewingRecentlyDeleted, let storage, let header, let key else { return }
        let parent = folderID; let manifest = manifest
        run("Encrypting and verifying imports…", operation: { try storage.importSources(urls, parent: parent, manifest: manifest, vaultID: header.id, key: key) }) { result in
            self.manifest = result.manifest; self.importResult = result
        }
    }
    func trashOriginals(_ result: ImportResult) {
        guard let storage, let header, let key, unlocked else { return }
        importResult = nil
        run("Checking originals before moving to Trash…", operation: {
            var failures: [String] = []; var count = 0
            for receipt in result.receipts {
                do {
                    try Task.checkCancellation()
                    try storage.verifyStoredCopy(receipt, vaultID: header.id, key: key)
                    try storage.verifyOriginal(receipt)
                    try Task.checkCancellation()
                    try FileManager.default.trashItem(at: receipt.source, resultingItemURL: nil)
                    count += 1
                } catch { failures.append("\(receipt.source.lastPathComponent): \(error.localizedDescription)") }
            }
            return (count, failures)
        }) { count, failures in
            self.notice = "\(count) original item\(count == 1 ? "" : "s") moved to Trash. Vault copies are ready."
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
        }
    }
    func newFolder() {
        guard let storage, let header, let key, !busy, !viewingRecentlyDeleted else { return }
        prompt(title: "New folder", message: "Create a folder inside this vault.", value: "Untitled Folder") { name in
            var next = self.manifest
            next.items.append(VaultItem(id: UUID(), parent: self.folderID, name: name, isFolder: true, size: 0, created: Date(), modified: Date(), digest: nil))
            let snapshot = next
            self.run("Creating folder…", operation: { try storage.saveManifest(snapshot, vaultID: header.id, key: key); return snapshot }) { self.manifest = $0 }
        }
    }
    func rename(_ item: VaultItem) {
        guard let storage, let header, let key, !busy, !item.isDeleted else { return }
        prompt(title: "Rename", message: "Choose a new name.", value: item.name) { name in
            var next = self.manifest
            if let index = next.items.firstIndex(where: { $0.id == item.id }) { next.items[index].name = name }
            let snapshot = next
            self.run("Renaming…", operation: { try storage.saveManifest(snapshot, vaultID: header.id, key: key); return snapshot }) { self.manifest = $0 }
        }
    }
    func move(_ item: VaultItem, to parent: UUID?) {
        guard let storage, let header, let key, !busy else { return }
        var next = manifest
        if let index = next.items.firstIndex(where: { $0.id == item.id }) { next.items[index].parent = parent }
        let snapshot = next
        run("Moving item…", operation: { try storage.saveManifest(snapshot, vaultID: header.id, key: key); return snapshot }) { self.manifest = $0; self.clearSelection(); self.closeQuickView() }
    }
    func delete(_ item: VaultItem) {
        guard !item.isDeleted else { return }
        moveToRecentlyDeleted([item])
    }
    func export(_ item: VaultItem) {
        guard let storage, let header, unlocked, !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Export decrypted copy"; panel.prompt = "Export"
        panel.message = "The exported copy will be readable outside the vault. Choose a new filename."
        panel.nameFieldStringValue = item.name; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard self.unlocked, self.selectedVaultID == header.id, let key = self.key else { return }
                let manifest = self.manifest
                self.run("Exporting verified copy…", operation: { try storage.export(item, to: url, manifest: manifest, vaultID: header.id, key: key) }) { _ in self.notice = "Exported \(item.name). This copy is outside the vault’s protection." }
            }
        }
    }
    var topLevelSelection: [VaultItem] {
        selectedItems.filter { item in
            var parent = item.parent
            while let id = parent, let ancestor = manifest.items.first(where: { $0.id == id }) {
                if selectionIDs.contains(id) { return false }; parent = ancestor.parent
            }
            return true
        }
    }
    func exportSelection() {
        let items = topLevelSelection
        guard unlocked, !busy, let storage, let header, !items.isEmpty else { return }
        if items.count == 1 { export(items[0]); return }
        let panel = NSOpenPanel()
        panel.title = "Export selected copies"; panel.message = "Choose a destination. Exported copies will be readable outside the vault."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Export copies"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                guard self.unlocked, self.selectedVaultID == header.id, let key = self.key else { return }
                let snapshot = self.manifest
                self.run("Exporting selected copies…", operation: {
                    let destination = folder.appendingPathComponent("Harbor export " + UUID().uuidString.prefix(8), isDirectory: true)
                    let stage = folder.appendingPathComponent(".harbor-batch-" + UUID().uuidString, isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: stage) }
                    try VaultStorage.directory(stage)
                    for item in items {
                        var name = item.name; var counter = 2
                        while FileManager.default.fileExists(atPath: stage.appendingPathComponent(name).path) {
                            let ext = (item.name as NSString).pathExtension
                            let base = ext.isEmpty ? item.name : (item.name as NSString).deletingPathExtension
                            name = "\(base) (\(counter))" + (ext.isEmpty ? "" : "." + ext); counter += 1
                        }
                        try storage.export(item, to: stage.appendingPathComponent(name), manifest: snapshot, vaultID: header.id, key: key)
                    }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: stage, to: destination)
                    return destination.lastPathComponent
                }) { name in self.notice = "Exported \(items.count) items to \(name). These copies are outside the vault’s protection." }
            }
        }
    }
    func deleteSelection() {
        if viewingRecentlyDeleted { permanentlyDeleteSelection(); return }
        moveToRecentlyDeleted(topLevelSelection)
    }
    func moveSelection(to parent: UUID?) {
        let items = topLevelSelection
        guard unlocked, !busy, !viewingRecentlyDeleted, let storage, let header, let key, !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        var snapshot = manifest
        for index in snapshot.items.indices where ids.contains(snapshot.items[index].id) { snapshot.items[index].parent = parent }
        let next = snapshot
        run("Moving selected items…", operation: { try storage.saveManifest(next, vaultID: header.id, key: key); return next }) { self.manifest = $0; self.clearSelection(); self.closeQuickView() }
    }
    func beginDeleteVault(_ header: VaultHeader) {
        guard !busy else { return }
        showSettings = false; showCreate = false
        lock(); selectedVaultID = header.id
        protectedAction = VaultActionRequest(kind: .delete, header: header)
    }
    func renameVault(_ header: VaultHeader) {
        guard unlocked, selectedVaultID == header.id, !busy, let storage else { return }
        prompt(title: "Rename vault", message: "Choose a neutral label. Vault names are visible while locked.", value: header.name) { name in
            guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                self.error = "Use a vault name of 1–64 characters without control characters."; return
            }
            self.run("Renaming vault…", operation: {
                var updated = try storage.loadHeader(header.id)
                updated.name = name
                try storage.saveHeader(updated)
            }) { _ in self.reload(); self.notice = "Vault renamed." }
        }
    }
    func beginShare() {
        let items = topLevelSelection
        guard unlocked, !busy, let header, !items.isEmpty else { return }
        let request = VaultActionRequest(kind: .share, header: header, items: items)
        lock(); protectedAction = request
    }
    func beginSharePreview() {
        guard let item = quickViewItem else { return }
        let items = quickViewIsGroup ? quickViewItems : [item]
        setSelection(Set(items.map(\.id)), lead: item.id)
        closeQuickView(); beginShare()
    }
    func cancelProtectedAction() {
        guard !busy else { return }
        protectedAction = nil; actionPermit = nil; actionKey = nil; actionAuthenticatedAt = nil; error = nil
    }
    var actionAuthenticated: Bool {
        guard let request = protectedAction else { return false }
        return actionPermit?.isFresh(for: request.header.id) == true
    }
    func authenticateProtectedAction(passcode: String? = nil, useMac: Bool = false) {
        guard !busy, let storage, let request = protectedAction else { return }
        let context = LAContext()
        context.localizedReason = request.kind == .delete ? "Authorize deleting this Harbor vault" : "Authorize sharing files from this Harbor vault"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authContext = context
        run("Verifying authorization…", operation: {
            defer { context.invalidate() }
            let fresh = try storage.loadHeader(request.header.id)
            guard fresh.name == request.header.name else { throw VaultError.message("The vault was renamed. Close this dialog and start again.") }
            let key: SymmetricKey
            if useMac {
                guard let mac = fresh.macUnlock else { throw VaultError.message("This vault requires its own passcode.") }
                key = try VaultCrypto.macKey(mac, vaultID: fresh.id, context: context)
            } else {
                guard let passcode, !passcode.isEmpty else { throw VaultError.message("Enter this vault’s passcode.") }
                key = try storage.passcodeKey(passcode, header: fresh)
            }
            let permit = VaultActionPermit(vaultID: fresh.id, headerFingerprint: try VaultStorage.headerFingerprint(fresh), authenticatedAt: Date())
            return (permit, key)
        }) { permit, key in
            guard self.protectedAction?.id == request.id else { return }
            self.authContext = nil; self.actionPermit = permit; self.actionKey = key; self.actionAuthenticatedAt = permit.authenticatedAt
        }
    }
    func confirmDeleteVault(_ confirmation: String) {
        guard !busy, let storage, let request = protectedAction, request.kind == .delete,
              let permit = actionPermit, permit.allowsDeletion(of: request.header, confirmation: confirmation) else {
            actionPermit = nil; actionKey = nil; actionAuthenticatedAt = nil
            error = "Authenticate again and type the exact deletion phrase."; return
        }
        run("Deleting vault…", operation: {
            guard permit.allowsDeletion(of: request.header, confirmation: confirmation) else { throw VaultError.message("Authentication expired. Verify again.") }
            return try storage.deleteVault(request.header.id, expectedFingerprint: permit.headerFingerprint)
        }) { cleanupWarning in
            self.lock(); self.selectedVaultID = nil; self.reload()
            self.notice = cleanupWarning ?? "Vault deleted."
        }
    }
    func prepareVerifiedShare() {
        guard !busy, let storage, let request = protectedAction, request.kind == .share,
              let permit = actionPermit, permit.isFresh(for: request.header.id), let key = actionKey else {
            actionPermit = nil; actionKey = nil; actionAuthenticatedAt = nil
            error = "Authenticate again before sharing."; return
        }
        run("Preparing verified share copies…", operation: {
            guard permit.isFresh(for: request.header.id), try VaultStorage.headerFingerprint(storage.loadHeader(request.header.id)) == permit.headerFingerprint else { throw VaultError.message("Authorization expired or the vault changed. Verify again.") }
            let snapshot = try storage.loadManifest(vaultID: request.header.id, key: key)
            return try VaultShareFiles.prepare(request.items, storage: storage, manifest: snapshot, vaultID: request.header.id, key: key)
        }) { prepared in
            self.protectedAction = nil; self.actionKey = nil; self.actionPermit = nil; self.actionAuthenticatedAt = nil
            self.shareSession = VaultShareSession(files: prepared) { [weak self] message in self?.notice = message; self?.shareSession = nil }
            let session = self.shareSession
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session?.present() }
        }
    }
    func showRecentlyDeleted(_ show: Bool) {
        guard unlocked else { return }
        closeQuickView(); closeSmallPreview()
        viewingRecentlyDeleted = show; folderID = nil; query = ""; clearSelection()
        backHistory = []; forwardHistory = []
    }
    func pathForFolder(_ id: UUID?) -> String {
        var names: [String] = []; var current = id
        while let value = current, let folder = manifest.items.first(where: { $0.id == value }) { names.insert(folder.name, at: 0); current = folder.parent }
        return names.isEmpty ? "All files" : "All files / " + names.joined(separator: " / ")
    }
    private func acceptTrashManifest(_ next: VaultManifest) {
        manifest = next
        if let folderID, !next.items.contains(where: { $0.id == folderID && $0.isFolder && !$0.isDeleted }) { self.folderID = nil; query = "" }
        let valid = Set(next.items.map(\.id))
        setSelection(selectionIDs.intersection(Set(visible.map(\.id))), lead: selection)
        if let item = quickViewItem, !valid.contains(item.id) { closeQuickView() }
        else { quickViewItems.removeAll { !valid.contains($0.id) } }
        if let item = smallPreviewItem, !valid.contains(item.id) { closeSmallPreview() }
    }
    private func moveToRecentlyDeleted(_ items: [VaultItem]) {
        guard unlocked, !busy, !viewingRecentlyDeleted, let storage, let header, let key, !items.isEmpty else { return }
        let snapshot = manifest
        let retention = snapshot.retentionDays == 0 ? "until you delete them permanently" : "for \(snapshot.retentionDays) days"
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Move “\(items[0].name)” to Recently Deleted?" : "Move \(items.count) items to Recently Deleted?"
        alert.informativeText = "The encrypted copies remain recoverable \(retention). You can change their deletion dates in Recently Deleted."
        alert.addButton(withTitle: "Move to Recently Deleted"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, unlocked else { return }
        run("Moving to Recently Deleted…", operation: { try storage.trashItems(items, manifest: snapshot, vaultID: header.id, key: key) }) { next in
            self.closeQuickView(); self.closeSmallPreview(); self.acceptTrashManifest(next); self.clearSelection()
            self.notice = "\(items.count) item\(items.count == 1 ? "" : "s") moved to Recently Deleted."
        }
    }
    func restoreSelection() {
        let items = selectedItems
        guard unlocked, !busy, viewingRecentlyDeleted, !items.isEmpty else { return }
        restoreRequest = RestoreRequest(items: items)
    }
    func confirmRestore(_ request: RestoreRequest, destination: RestoreDestination) {
        let items = request.items
        guard unlocked, !busy, viewingRecentlyDeleted, let storage, let header, let key, !items.isEmpty else { return }
        let snapshot = manifest
        run("Restoring deleted items…", operation: { try storage.restoreItems(items, manifest: snapshot, vaultID: header.id, key: key, destination: destination) }) { next in
            self.closeQuickView(); self.closeSmallPreview(); self.manifest = next; self.clearSelection()
            self.restoreRequest = nil
            self.notice = "Restored \(items.count) item\(items.count == 1 ? "" : "s"). Existing names are preserved with numbered copies when needed."
        }
    }
    func editDeletionDate() {
        let items = selectedItems
        guard unlocked, !busy, viewingRecentlyDeleted, !items.isEmpty else { return }
        trashDateEdit = TrashDateRequest(items: items)
    }
    func saveDeletionDate(_ date: Date?, request: TrashDateRequest) {
        guard unlocked, !busy, let storage, let header, let key else { return }
        let snapshot = manifest
        run("Updating deletion date…", operation: { try storage.updateDeletionDate(date, for: request.items, manifest: snapshot, vaultID: header.id, key: key) }) { next in
            self.manifest = next; self.trashDateEdit = nil
            self.notice = date == nil ? "Selected items will stay until you delete them permanently." : "Permanent-deletion date updated."
        }
    }
    func setTrashRetention(_ days: Int) {
        guard unlocked, !busy, let storage, let header, let key else { return }
        let snapshot = manifest
        run("Updating this vault’s retention…", operation: { try storage.updateTrashRetention(days, manifest: snapshot, vaultID: header.id, key: key) }) { next in self.manifest = next }
    }
    func permanentlyDeleteSelection(all: Bool = false) {
        let items = all ? manifest.recentlyDeleted : selectedItems
        guard unlocked, !busy, viewingRecentlyDeleted, let storage, let header, let key, !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = all ? "Empty Recently Deleted in this vault?" : "Permanently delete \(items.count) selected item\(items.count == 1 ? "" : "s")?"
        alert.informativeText = "The encrypted copies and any selected folder contents will be removed permanently. This cannot be undone. Other copies and backups are separate."
        alert.alertStyle = .warning; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Permanently")
        guard alert.runModal() == .alertSecondButtonReturn, unlocked else { return }
        let snapshot = manifest
        run("Permanently deleting copies…", operation: { try storage.permanentlyDeleteTrash(items, manifest: snapshot, vaultID: header.id, key: key) }) { next in
            self.closeQuickView(); self.closeSmallPreview(); self.acceptTrashManifest(next); self.clearSelection(); self.thumbnails.clear()
            self.notice = "Permanently deleted \(items.count) item\(items.count == 1 ? "" : "s")."
        }
    }
    func purgeExpiredTrashIfNeeded(now: Date = Date()) {
        guard unlocked, !busy, !viewerAuthenticating, protectedAction == nil, trashDateEdit == nil, restoreRequest == nil, transferRequest == nil,
              !showCreate, !showPasscodeSettings, let storage, let header, let key else { return }
        lastTrashPurge = now
        guard manifest.recentlyDeleted.contains(where: { $0.permanentDeletionDate.map { $0 <= now } == true }) else { return }
        let snapshot = manifest
        run("Removing expired deleted copies…", recordsActivity: false, operation: { try storage.purgeExpiredTrash(manifest: snapshot, vaultID: header.id, key: key, now: now) }) { next in
            self.acceptTrashManifest(next); self.thumbnails.clear()
        }
    }
    func beginTransfer() {
        let items = topLevelSelection
        guard unlocked, !busy, !viewingRecentlyDeleted, let header, !items.isEmpty else { return }
        guard let destination = vaults.first(where: { $0.id != header.id }) else { error = "Create another vault before transferring files."; return }
        closeQuickView(); closeSmallPreview()
        transferRequest = VaultTransferRequest(source: header, items: items)
        selectTransferDestination(destination.id)
    }
    func selectTransferDestination(_ id: UUID) {
        guard !busy, let request = transferRequest, id != request.source.id else { return }
        transferContext?.invalidate(); transferContext = nil
        transferDestinationID = id; transferAuthenticatedAt = nil; transferPermit = nil; transferDestinationKey = nil; error = nil
    }
    var transferAuthenticated: Bool {
        guard let id = transferDestinationID else { return false }
        return transferPermit?.isFresh(for: id) == true
    }
    func cancelTransfer() {
        guard !busy else { return }
        transferContext?.invalidate(); transferContext = nil
        transferRequest = nil; transferDestinationID = nil; transferAuthenticatedAt = nil; transferPermit = nil; transferDestinationKey = nil; error = nil
    }
    func authenticateTransferDestination(passcode: String? = nil, useMac: Bool = false) {
        guard unlocked, !busy, let storage, let request = transferRequest, let destination = transferDestinationID else { return }
        let context = LAContext()
        context.localizedReason = "Authorize receiving files in the destination vault"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        transferContext = context
        run("Verifying destination vault…", operation: {
            defer { context.invalidate() }
            let header = try storage.loadHeader(destination)
            let key: SymmetricKey
            if useMac {
                guard let mac = header.macUnlock else { throw VaultError.message("This destination vault requires its own passcode.") }
                key = try VaultCrypto.macKey(mac, vaultID: destination, context: context)
            } else {
                guard let passcode, !passcode.isEmpty else { throw VaultError.message("Enter the destination vault’s passcode.") }
                key = try storage.passcodeKey(passcode, header: header)
            }
            _ = try storage.loadManifest(vaultID: destination, key: key)
            return (key, VaultActionPermit(vaultID: destination, headerFingerprint: try VaultStorage.headerFingerprint(header), authenticatedAt: Date()))
        }) { key, permit in
            guard self.transferRequest?.id == request.id, self.transferDestinationID == destination else { return }
            self.transferContext = nil; self.transferDestinationKey = key; self.transferPermit = permit; self.transferAuthenticatedAt = permit.authenticatedAt
        }
    }
    func confirmTransfer(mode: VaultTransferMode) {
        guard unlocked, !busy, let storage, let sourceKey = key, let request = transferRequest,
              selectedVaultID == request.source.id, let destination = transferDestinationID, let destinationKey = transferDestinationKey,
              let permit = transferPermit, permit.isFresh(for: destination) else { error = "Verify the destination vault first."; return }
        let snapshot = manifest
        run(mode == .move ? "Moving to the other vault…" : "Duplicating into the other vault…", operation: {
            guard permit.isFresh(for: destination), try VaultStorage.headerFingerprint(storage.loadHeader(destination)) == permit.headerFingerprint else { throw VaultError.message("Destination verification expired or its settings changed. Verify again.") }
            return try storage.transferItems(request.items, from: request.source.id, sourceManifest: snapshot, sourceKey: sourceKey,
                to: destination, destinationKey: destinationKey, mode: mode)
        }) { result in
            self.acceptTrashManifest(result.sourceManifest); self.clearSelection(); self.thumbnails.clear()
            self.transferRequest = nil; self.transferDestinationID = nil; self.transferPermit = nil; self.transferDestinationKey = nil; self.transferAuthenticatedAt = nil
            self.notice = result.warning ?? (result.moved ? "Moved to the destination vault. Only one active copy remains across the two vaults." : "Duplicated into the destination vault. Both copies are available.")
        }
    }
    private func prompt(title: String, message: String, value: String, completion: (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, unlocked { completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

struct PreviewContent: Identifiable {
    var id: UUID { item.id }
    let item: VaultItem
    let data: Data
}
