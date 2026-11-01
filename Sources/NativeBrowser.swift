import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NativeFileBrowser: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }
    @MainActor static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let collection = FileCollectionView()
        collection.model = coordinator.model
        collection.onOpenItem = { [weak model = coordinator.model] item in
            guard let model else { return }
            if model.selectionIDs.count > 1 { model.showQuickView(item) } else { model.open(item) }
        }
        collection.onSmallPreview = { [weak model = coordinator.model] item, anchor in model?.showSmallPreview(item, anchoredTo: anchor) }
        collection.autoresizingMask = [.width]
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = coordinator; collection.delegate = coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14; layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 18, right: 10)
        collection.collectionViewLayout = layout
        // Installing a modern layout replaces AppKit's legacy collection core.
        // Register cells afterward so the new core owns their registration.
        collection.register(FileCollectionItem.self, forItemWithIdentifier: FileCollectionItem.identifier)
        scroll.documentView = collection
        coordinator.collection = collection
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard let collection = scroll.documentView as? FileCollectionView else { return }
        collection.model = model
        let items = model.visible
        let signature = "\(model.grid)/\(model.thumbnailSize)/\(model.textScale)/\(model.density)/\(model.viewingRecentlyDeleted)"
        let changed = context.coordinator.items != items || context.coordinator.signature != signature
        context.coordinator.items = items; collection.items = items
        if changed {
            context.coordinator.signature = signature
            collection.reloadData(); collection.collectionViewLayout?.invalidateLayout()
        }
        context.coordinator.syncSelection()
        for path in collection.indexPathsForVisibleItems() {
            if let item = collection.item(at: path) as? FileCollectionItem { context.coordinator.configure(item, path: path) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let collection = scroll.documentView as? FileCollectionView {
            for path in collection.indexPathsForVisibleItems() {
                if let cell = collection.item(at: path) as? FileCollectionItem { cell.canvas.thumbnail = nil; cell.canvas.entry = nil }
            }
            collection.items = []; collection.model = nil; collection.dataSource = nil; collection.delegate = nil
        }
        scroll.documentView = nil
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var model: AppModel
        var items: [VaultItem] = []
        var signature = ""
        weak var collection: FileCollectionView?
        init(_ model: AppModel) { self.model = model }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileCollectionItem.identifier, for: indexPath) as! FileCollectionItem
            configure(item, path: indexPath)
            return item
        }
        func configure(_ cell: FileCollectionItem, path: IndexPath) {
            guard items.indices.contains(path.item) else { return }
            let item = items[path.item]
            let canvas = cell.canvas
            let changedID = canvas.entry?.id != item.id
            if changedID { canvas.thumbnail = nil; canvas.requestedID = nil }
            canvas.entry = item; canvas.grid = model.grid; canvas.textScale = model.textScale
            canvas.inTrash = model.viewingRecentlyDeleted
            canvas.browser = collection
            canvas.selected = model.selectionIDs.contains(item.id)
            canvas.onPress = { [weak self, weak canvas] in
                guard let canvas else { return }
                self?.collection?.handleItemClick(item.id, clickCount: 1, modifiers: [], anchor: canvas)
            }
            canvas.setAccessibilityLabel("\(item.name), \(item.isFolder ? "folder" : "file")")
            canvas.setAccessibilityValue(canvas.selected ? "Selected" : "Not selected")
            canvas.needsDisplay = true
            if !item.isFolder, canvas.requestedID != item.id {
                canvas.requestedID = item.id
                model.requestThumbnail(item) { [weak canvas] image in
                    guard canvas?.entry?.id == item.id else { return }
                    canvas?.thumbnail = image; canvas?.needsDisplay = true
                }
            }
        }
        func syncSelection() {
            guard let collection else { return }
            let paths = Set(items.enumerated().compactMap { model.selectionIDs.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
            if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
            for path in collection.indexPathsForVisibleItems() {
                if let cell = collection.item(at: path) as? FileCollectionItem { cell.canvas.selected = paths.contains(path); cell.canvas.needsDisplay = true }
            }
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            let width = collectionView.enclosingScrollView?.contentSize.width ?? 600
            if model.grid { return NSSize(width: model.thumbnailSize + 28, height: model.thumbnailSize + 63 * model.textScale) }
            return NSSize(width: max(100, width - 20), height: (model.density == "compact" ? 43 : 58) * model.textScale)
        }
    }
}

@MainActor final class FileCollectionView: NSCollectionView {
    weak var model: AppModel?
    var items: [VaultItem] = []
    var onOpenItem: ((VaultItem) -> Void)?
    var onSmallPreview: ((VaultItem, NSView) -> Void)?
    private var collapse: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let attributes = collectionViewLayout?.layoutAttributesForElements(in: NSRect(x: local.x, y: local.y, width: 1, height: 1)) ?? []
        if let path = attributes.first(where: { $0.representedElementCategory == .item && $0.frame.contains(local) })?.indexPath,
           let cell = item(at: path) as? FileCollectionItem { return cell.canvas }
        // AppKit's private cell wrappers must not consume our custom click handling.
        return self
    }
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let scroll = enclosingScrollView {
            size.width = max(0, scroll.contentSize.width)
            size.height = max(size.height, scroll.contentSize.height)
        }
        super.setFrameSize(size)
    }
    override func mouseDown(with event: NSEvent) {
        guard let model, model.unlocked else { return }
        window?.makeFirstResponder(self)
        collapse?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), items.indices.contains(path.item) {
            let anchor = (item(at: path) as? FileCollectionItem)?.view ?? self
            handleItemClick(items[path.item].id, clickCount: event.clickCount, modifiers: event.modifierFlags, anchor: anchor)
            return
        }
        model.closeSmallPreview()
        let initial = model.selectionIDs
        let shift = event.modifierFlags.contains(.shift), command = event.modifierFlags.contains(.command)
        if !shift && !command { model.clearSelection(); syncSelection() }
        let overlay = MarqueeOverlay(frame: .zero)
        addSubview(overlay, positioned: .above, relativeTo: nil)
        defer { overlay.removeFromSuperview() }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let current = convert(next.locationInWindow, from: nil)
            let rect = NSRect(x: min(point.x, current.x), y: min(point.y, current.y), width: abs(point.x - current.x), height: abs(point.y - current.y))
            overlay.frame = rect; overlay.needsDisplay = true
            let attributes = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
            let hits = Set(attributes.compactMap { attribute -> UUID? in
                guard attribute.representedElementCategory == .item, attribute.frame.intersects(rect), let path = attribute.indexPath, items.indices.contains(path.item) else { return nil }
                return items[path.item].id
            })
            model.setSelection(BrowserSelection.marquee(hits: hits, initial: initial, shift: shift, command: command))
            syncSelection()
            displayIfNeeded()
        }
    }
    func handleItemClick(_ id: UUID, clickCount: Int, modifiers: NSEvent.ModifierFlags, anchor: NSView) {
        guard let model, model.unlocked, let item = items.first(where: { $0.id == id }) else { return }
        window?.makeFirstResponder(self)
        collapse?.cancel()
        model.closeSmallPreview()
        if clickCount >= 2 {
            if !model.selectionIDs.contains(id) { model.select(id) }
            syncSelection()
            onOpenItem?(item)
            return
        }
        let shift = modifiers.contains(.shift), command = modifiers.contains(.command)
        if model.selectionIDs.count > 1, model.selectionIDs.contains(id), !shift, !command {
            // Keep a selected group intact until we know whether this is a double-click.
            let work = DispatchWorkItem { [weak self, weak model] in
                guard let self, let model, model.unlocked else { return }
                model.select(id); self.syncSelection()
            }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.03, execute: work)
        } else {
            model.select(id, shift: shift, command: command)
            syncSelection()

        }
    }
    private func toggleSmallPreview() {
        guard let model else { return }
        collapse?.cancel()
        if model.smallPreviewItem != nil { model.closeSmallPreview(); return }
        guard let selected = model.selectedItem, let index = items.firstIndex(where: { $0.id == selected.id }) else { return }
        let anchor = item(at: IndexPath(item: index, section: 0))?.view ?? self
        onSmallPreview?(selected, anchor)
    }
    override func keyDown(with event: NSEvent) {
        guard let model, model.unlocked else { return }
        let flags = event.modifierFlags
        if flags.contains(.command) {
            switch event.keyCode {
            case 0: model.selectAll(); syncSelection(); return
            case 125: if let item = model.selectedItem { if model.selectionIDs.count > 1 { model.showQuickView(item) } else { model.open(item) } }; return
            case 126: model.goUp(); return
            case 51: model.deleteSelection(); return
            default: super.keyDown(with: event); return
            }
        }
        switch event.keyCode {
        case 49: toggleSmallPreview()
        case 53: model.closeSmallPreview(); model.clearSelection(); syncSelection()
        case 123, 124, 125, 126:
            let width = enclosingScrollView?.contentSize.width ?? bounds.width
            let columns = model.grid ? max(1, Int((width - 20 + 14) / (model.thumbnailSize + 28 + 14))) : 1
            let offset = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
            model.moveSelection(by: offset, extend: flags.contains(.shift)); syncSelection(); revealLead()
        case 36: if let item = model.selectedItem, model.selectionIDs.count == 1 { model.rename(item) }
        default: super.keyDown(with: event)
        }
    }
    override func selectAll(_ sender: Any?) { model?.selectAll(); syncSelection() }
    override func deselectAll(_ sender: Any?) { model?.clearSelection(); syncSelection() }
    private func revealLead() {
        if let id = model?.selection, let index = items.firstIndex(where: { $0.id == id }) { scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge)) }
    }
    private func syncSelection() {
        guard let model else { return }
        selectionIndexPaths = Set(items.enumerated().compactMap { model.selectionIDs.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
        for path in indexPathsForVisibleItems() {
            if let cell = item(at: path) as? FileCollectionItem { cell.canvas.selected = items.indices.contains(path.item) && model.selectionIDs.contains(items[path.item].id); cell.canvas.needsDisplay = true }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, !model.busy else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point), items.indices.contains(path.item) else { return nil }
        let item = items[path.item]
        if !model.selectionIDs.contains(item.id) { model.select(item.id); syncSelection() }
        let multiple = model.selectionIDs.count > 1
        let menu = NSMenu()
        if model.viewingRecentlyDeleted {
            menu.addItem(FileMenuItem("Quick View") { [weak model] in model?.showQuickView(item) })
            menu.addItem(.separator())
            menu.addItem(FileMenuItem("Restore") { [weak model] in model?.restoreSelection() })
            menu.addItem(FileMenuItem("Change permanent-deletion date…") { [weak model] in model?.editDeletionDate() })
            menu.addItem(.separator())
            menu.addItem(FileMenuItem("Delete Permanently…") { [weak model] in model?.permanentlyDeleteSelection() })
            return menu
        }
        menu.addItem(FileMenuItem(multiple ? "Quick View \(model.selectionIDs.count) items" : item.isFolder ? "Open folder" : "Quick View") { [weak model] in
            if multiple { model?.showQuickView(item) } else { model?.open(item) }
        })
        menu.addItem(FileMenuItem("Export \(multiple ? "selected copies" : "decrypted copy")…") { [weak model] in model?.exportSelection() })
        menu.addItem(FileMenuItem("Share… (verify identity)") { [weak model] in model?.beginShare() })
        menu.addItem(FileMenuItem("Send to another vault…") { [weak model] in model?.beginTransfer() })
        if !multiple {
            menu.addItem(.separator())
            menu.addItem(FileMenuItem("Rename…") { [weak model] in model?.rename(item) })
        }
        let moveMenu = NSMenu(title: "Move to")
        moveMenu.addItem(FileMenuItem("All files") { [weak model] in model?.moveSelection(to: nil) })
        for folder in model.manifest.items.filter({ $0.isFolder && !$0.isDeleted && !model.selectionIDs.contains($0.id) }).sorted(by: { $0.name < $1.name }) {
            moveMenu.addItem(FileMenuItem(folder.name) { [weak model] in model?.moveSelection(to: folder.id) })
        }
        let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu; menu.addItem(moveItem)
        menu.addItem(.separator())
        menu.addItem(FileMenuItem("Move \(multiple ? "selected items" : "item") to Recently Deleted…") { [weak model] in model?.deleteSelection() })
        return menu
    }
}

@MainActor final class FileMenuItem: NSMenuItem {
    let callback: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        callback = action; super.init(title: title, action: #selector(invoke), keyEquivalent: ""); target = self
    }
    required init(coder: NSCoder) { fatalError("Not used") }
    @objc private func invoke() { callback() }
}

@MainActor final class FileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HarborFile")
    var canvas: FileItemCanvas { view as! FileItemCanvas }
    override func loadView() { view = FileItemCanvas() }
    override var isSelected: Bool { didSet { if isViewLoaded { canvas.selected = isSelected; canvas.needsDisplay = true } } }
    override func prepareForReuse() {
        super.prepareForReuse(); canvas.thumbnail = nil; canvas.entry = nil; canvas.requestedID = nil; canvas.onPress = nil; canvas.browser = nil
    }
}
@MainActor final class MarqueeOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(HarborDesign.amber).withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor(HarborDesign.amber).withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
    }
}

@MainActor final class FileItemCanvas: NSView {
    var entry: VaultItem?
    var thumbnail: NSImage?
    var requestedID: UUID?
    var grid = true
    var inTrash = false
    var selected = false
    var textScale: CGFloat = 1
    var onPress: (() -> Void)?
    weak var browser: FileCollectionView?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(true); setAccessibilityRole(.button) }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let entry else { return }
        browser?.handleItemClick(entry.id, clickCount: event.clickCount, modifiers: event.modifierFlags, anchor: self)
    }
    override func mouseUp(with event: NSEvent) { }
    override func menu(for event: NSEvent) -> NSMenu? { browser?.menu(for: event) }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        if selected {
            NSColor(HarborDesign.amber).withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: grid ? 13 : 9, yRadius: grid ? 13 : 9).fill()
        }
        if grid { drawGrid(entry) } else { drawRow(entry) }
    }
    private func font(_ size: CGFloat) -> NSFont { NSFont(name: "InstrumentSans-Regular", size: size * textScale) ?? .systemFont(ofSize: size * textScale) }
    private func text(_ string: String, rect: NSRect, size: CGFloat, color: NSColor = .labelColor, alignment: NSTextAlignment = .left, lines: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = lines ? .byWordWrapping : .byTruncatingMiddle
        (string as NSString).draw(in: rect, withAttributes: [.font: font(size), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func icon(_ entry: VaultItem) -> NSImage {
        if entry.isFolder {
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(paletteColors: [NSColor(HarborDesign.amber)]))!
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
    }
    private func drawGrid(_ entry: VaultItem) {
        let available = NSRect(x: 12, y: 9, width: bounds.width - 24, height: bounds.width - 28)
        let image = thumbnail ?? icon(entry)
        let ratio = min(available.width / max(1, image.size.width), available.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let rect = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let y = available.maxY + 7
        text(entry.name, rect: NSRect(x: 6, y: y, width: bounds.width - 12, height: 33 * textScale), size: 12, alignment: .center, lines: true)
        if inTrash {
            text(entry.permanentDeletionDate.map { "Deletes " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "Keep until deleted", rect: NSRect(x: 4, y: y + 34 * textScale, width: bounds.width - 8, height: 14 * textScale), size: 10, color: .secondaryLabelColor, alignment: .center)
        } else if !entry.isFolder { text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file), rect: NSRect(x: 4, y: y + 34 * textScale, width: bounds.width - 8, height: 14 * textScale), size: 10, color: .secondaryLabelColor, alignment: .center) }
    }
    private func drawRow(_ entry: VaultItem) {
        let image = thumbnail ?? icon(entry)
        let box = NSRect(x: 12, y: (bounds.height - 30) / 2, width: 30, height: 30)
        let ratio = min(box.width / max(1, image.size.width), box.height / max(1, image.size.height))
        let rect = NSRect(x: box.midX - image.size.width * ratio / 2, y: box.midY - image.size.height * ratio / 2, width: image.size.width * ratio, height: image.size.height * ratio)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let y = (bounds.height - 17 * textScale) / 2
        text(entry.name, rect: NSRect(x: 54, y: y, width: max(50, bounds.width - 340), height: 20 * textScale), size: 12)
        let kind = entry.isFolder ? "Folder" : (entry.name as NSString).pathExtension.uppercased() + " file"
        text(kind, rect: NSRect(x: bounds.width - 265, y: y, width: 85, height: 20 * textScale), size: 11, color: .secondaryLabelColor)
        text(entry.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file), rect: NSRect(x: bounds.width - 174, y: y, width: 74, height: 20 * textScale), size: 11, color: .secondaryLabelColor, alignment: .right)
        let date = inTrash ? entry.permanentDeletionDate.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "Never" : entry.created.formatted(.dateTime.month(.abbreviated).day())
        text(date, rect: NSRect(x: bounds.width - 88, y: y, width: 74, height: 20 * textScale), size: 11, color: .secondaryLabelColor, alignment: .right)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill(); NSRect(x: 12, y: bounds.height - 1, width: bounds.width - 24, height: 0.5).fill()
    }
}

