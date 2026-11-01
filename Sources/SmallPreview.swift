import SwiftUI
import AppKit

@MainActor final class SmallPreviewController: NSObject, NSPopoverDelegate {
    private weak var model: AppModel?
    private let popover = NSPopover()
    private var closing = false
    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 340, height: 300)
        let controller = NSViewController()
        controller.view = SmallPreviewHostingView(rootView: SmallPreviewContent().environmentObject(model), model: model)
        popover.contentViewController = controller
        popover.delegate = self
    }
    func show(anchoredTo anchor: NSView) {
        guard anchor.window != nil else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }
    func close() {
        guard !closing else { return }; closing = true
        popover.delegate = nil; popover.close(); popover.contentViewController = nil
    }
    func popoverDidClose(_ notification: Notification) {
        guard !closing else { return }; model?.closeSmallPreview()
    }
}
@MainActor final class SmallPreviewHostingView: NSHostingView<AnyView> {
    private weak var model: AppModel?
    convenience init<V: View>(rootView: V, model: AppModel) {
        self.init(rootView: AnyView(rootView))
        self.model = model
    }
    @MainActor required init(rootView: AnyView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 53 { model?.closeSmallPreview(); return }
        super.keyDown(with: event)
    }
}
struct SmallPreviewContent: View {
    @EnvironmentObject var model: AppModel
    @State private var zoom: Double = 1
    private typealias D = HarborDesign
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(model.smallPreviewItem?.name ?? "Preview").font(D.font(12, .medium)).lineLimit(1)
                Spacer(minLength: 5)
                Button { model.closeSmallPreview() } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("Dismiss preview")
            }.padding(14)
            Divider()
            Group {
                if model.smallPreviewLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let item = model.smallPreviewItem, item.isFolder {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.fill").font(.system(size: 48)).foregroundStyle(D.amber)
                        Text("\(model.childrenInPreview(of: item).count) items").font(D.font(11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = model.smallPreview {
                    QuickViewDocument(content: content, zoom: $zoom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: model.smallPreviewItem?.symbol ?? "doc").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        Text(model.smallPreviewError ?? "Preview unavailable").font(D.font(11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(D.canvas)
            Divider()
            Text("Double-click the file for the full viewer").font(D.font(10)).foregroundStyle(.secondary).padding(11)
        }.frame(width: 340, height: 300).background(D.surface)
            .preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
    }
}

