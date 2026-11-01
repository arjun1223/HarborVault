import SwiftUI
import AppKit
import PDFKit

@MainActor final class QuickViewController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private let panel: QuickViewPanel
    private var closing = false
    init(model: AppModel) {
        self.model = model
        panel = QuickViewPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.model = model; panel.delegate = self
        panel.title = "Quick View"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 700, height: 460)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuickViewContent().environmentObject(model))
        panel.center()
    }
    func show() { panel.makeKeyAndOrderFront(nil) }
    func close() {
        guard !closing else { return }; closing = true
        panel.delegate = nil; panel.orderOut(nil); panel.contentView = nil; panel.close()
    }
    func windowWillClose(_ notification: Notification) { if !closing { model?.closeQuickView() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.closeQuickView(); return false }
    func windowDidResignKey(_ notification: Notification) {
        // A file window must never keep readable content after the user leaves it.
        guard !closing, panel.isVisible else { return }
        model?.previewLostFocus()
    }
}
@MainActor final class QuickViewPanel: NSPanel {
    weak var model: AppModel?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if model?.viewerLocked == true {
            if event.type == .keyDown && event.keyCode == 53 { model?.closeQuickView(); return }
            super.sendEvent(event); return
        }
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch QuickViewKeyAction.action(for: event.keyCode) {
            case .close: model?.closeQuickView(); return
            case .previous: model?.quickViewStep(-1); return
            case .next: model?.quickViewStep(1); return
            case .ignore: return
            case .passThrough: break
            }
        }
        super.sendEvent(event)
    }
}

struct QuickViewContent: View {
    @EnvironmentObject var model: AppModel
    private typealias D = HarborDesign
    var body: some View {
        Group {
            if model.viewerLocked { ViewerUnlockView() }
            else { documentBody }
        }.frame(minWidth: 700, minHeight: 460)
            .background(D.canvas)
            .preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
    }
    private var documentBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: model.quickViewItem?.symbol ?? "doc").foregroundStyle(.secondary)
                Text(model.quickViewItem?.name ?? "Quick View").font(D.font(13, .medium)).lineLimit(1)
                Spacer()
                Text(model.quickViewPosition).font(D.font(11)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { model.previewZoom = max(0.25, model.previewZoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain).help("Zoom out")
                    Button { model.previewZoom = 1 } label: { Text("Fit").font(D.font(11)) }.buttonStyle(.plain)
                    Button { model.previewZoom = min(5, model.previewZoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain).help("Zoom in")
                }.padding(.horizontal, 14)
                Button { model.quickViewStep(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Previous file (←)")
                Button { model.quickViewStep(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).help("Next file (→)")
                Button("Close") { model.closeQuickView() }.buttonStyle(HarborButtonStyle(compact: true))
                Button { model.beginSharePreview() } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain).help(model.quickViewIsGroup ? "Share this selected group · requires verification" : "Share this file · requires verification")
            }.padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 16).background(D.surface)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.quickViewItems) { item in
                            QuickViewSidebarItem(item: item)
                        }
                    }.padding(12)
                }.frame(width: 170).background(D.sidebar)
                Divider()
            Group {
                if model.quickViewLoading { ProgressView("Decrypting preview…").font(D.font(12)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let item = model.quickViewItem, item.isFolder {
                    VStack(spacing: 15) {
                        Image(systemName: "folder.fill").font(.system(size: 70)).foregroundStyle(D.amber)
                        Text(item.name).font(D.heading(22))
                        Text("\(model.childrenInPreview(of: item).count) items").font(D.font(12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = model.preview { QuickViewDocument(content: content, zoom: $model.previewZoom) }
                else {
                    VStack(spacing: 15) {
                        Image(systemName: "doc").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                        Text("Preview unavailable").font(D.heading(19))
                        Text(model.quickViewError ?? "Export a copy to open this format in another app.").font(D.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let item = model.quickViewItem { Button("Export copy…") { model.closeQuickView(); model.export(item) }.buttonStyle(HarborButtonStyle(primary: true)) }
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(D.canvas)
            }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "lock")
                Text("Switching away locks this viewer. Your vault stays unlocked.").font(D.font(10))
                Spacer()
                Text("Space to close  ·  ← → to browse").font(D.font(10)).foregroundStyle(.tertiary)
            }.font(D.font(10)).foregroundStyle(.secondary).padding(14).background(D.surface)
        }.background(D.canvas).tint(D.amber)
            .preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
    }
}

struct QuickViewDocument: View {
    let content: PreviewContent
    @Binding var zoom: Double
    var body: some View {
        Group {
            if (content.item.name as NSString).pathExtension.lowercased() == "pdf", let document = PDFDocument(data: content.data) { ZoomedPDFView(document: document, id: content.item.id, zoom: $zoom) }
            else if let image = NSImage(data: content.data) { ZoomedImageView(image: image, id: content.item.id, zoom: $zoom) }
            else if content.data.count <= 2 * 1024 * 1024, let text = String(data: content.data, encoding: .utf8), !text.contains("\0") {
                ScrollView([.vertical, .horizontal]) { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(26) }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: content.item.symbol).font(.system(size: 50, weight: .light))
                    Text(content.item.name).font(HarborDesign.font(14))
                    Text(ByteCountFormatter.string(fromByteCount: content.item.size, countStyle: .file) + " · " + (content.item.name as NSString).pathExtension.uppercased()).font(HarborDesign.font(11)).foregroundStyle(.secondary)
                    Text("No in-app renderer for this format.").font(HarborDesign.font(12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct QuickViewSidebarItem: View {
    @EnvironmentObject var model: AppModel
    let item: VaultItem
    @State private var thumbnail: NSImage?
    var body: some View {
        Button { model.showQuickView(item) } label: {
            VStack(spacing: 7) {
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else { Image(systemName: item.symbol).font(.system(size: 32, weight: .light)).foregroundStyle(item.isFolder ? HarborDesign.amber : Color.secondary) }
                }.frame(width: 120, height: 100).padding(6).background(HarborDesign.surface, in: RoundedRectangle(cornerRadius: 8))
                Text(item.name).font(HarborDesign.font(11)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }.padding(6).background(model.quickViewItem?.id == item.id ? HarborDesign.amber.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.quickViewItem?.id == item.id ? HarborDesign.amber : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).accessibilityLabel(item.name)
            .onAppear { model.requestThumbnail(item) { thumbnail = $0 } }
    }
}
struct ViewerUnlockView: View {
    @EnvironmentObject var model: AppModel
    @State private var passcode = ""
    private typealias D = HarborDesign
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 19) {
                Image(systemName: "lock").font(.system(size: 27, weight: .light)).foregroundStyle(.secondary)
                Text("Viewer locked").font(D.heading(23, .semibold))
                Text("Verify to show the files in this window again. Your vault is still unlocked.").font(D.font(12)).foregroundStyle(.secondary).lineSpacing(3)
                if model.header?.macUnlock != nil {
                    Button { passcode = ""; model.authenticateViewer(useMac: true) } label: {
                        Label("Unlock with Touch ID / Mac password", systemImage: "touchid").frame(maxWidth: .infinity)
                    }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.viewerAuthenticating)
                }
                HStack(spacing: 9) {
                    PasswordEntry("This vault’s passcode", text: $passcode).harborField().onSubmit(verify)
                    Button("Unlock", action: verify).buttonStyle(HarborButtonStyle()).disabled(passcode.isEmpty || model.viewerAuthenticating)
                }
                if model.viewerAuthenticating { ProgressView("Verifying…").font(D.font(11)) }
                if let error = model.viewerAuthError { Text(error).font(D.font(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Button("Close viewer") { model.closeQuickView() }.buttonStyle(.plain).font(D.font(11)).foregroundStyle(.secondary)
            }.padding(28).frame(width: 440).harborSurface(radius: 18)
            Spacer(minLength: 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(D.canvas)
    }
    private func verify() {
        guard !passcode.isEmpty, !model.viewerAuthenticating else { return }
        let input = passcode; passcode = ""; model.authenticateViewer(passcode: input)
    }
}

