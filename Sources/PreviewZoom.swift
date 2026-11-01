import SwiftUI
import AppKit
import PDFKit

enum PreviewZoom {
    static let minimum = 0.25
    static let maximum = 5.0
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(maximum, max(minimum, value)) : 1 }
    static func fit(image: NSSize, viewport: NSSize) -> NSSize {
        guard image.width > 0, image.height > 0 else { return NSSize(width: 1, height: 1) }
        let ratio = max(0.001, min(max(1, viewport.width - 36) / image.width, max(1, viewport.height - 36) / image.height))
        return NSSize(width: image.width * ratio, height: image.height * ratio)
    }
}

@MainActor final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return bounds }
        if document.frame.width < bounds.width { bounds.origin.x = (document.frame.width - bounds.width) / 2 }
        if document.frame.height < bounds.height { bounds.origin.y = (document.frame.height - bounds.height) / 2 }
        return bounds
    }
}

@MainActor final class PinchImageScrollView: NSScrollView {
    let imageView = NSImageView()
    var representedID: UUID?
    var onZoom: ((Double) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteredImageClipView()
        drawsBackground = false; contentView.drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        allowsMagnification = true
        minMagnification = PreviewZoom.minimum; maxMagnification = PreviewZoom.maximum
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        documentView = imageView
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        guard let image = imageView.image else { return }
        let fitted = PreviewZoom.fit(image: image.size, viewport: contentView.frame.size)
        if imageView.frame.size != fitted { imageView.setFrameSize(fitted); reflectScrolledClipView(contentView) }
    }
    func setControlZoom(_ value: Double) {
        let next = PreviewZoom.clamp(value)
        if abs(magnification - next) > 0.0001 {
            let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
            setMagnification(next, centeredAt: center)
        }
    }
    func publishZoom() { onZoom?(PreviewZoom.clamp(magnification)) }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        publishZoom()
    }
    override func smartMagnify(with event: NSEvent) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(magnification > 1.05 ? 1 : 2, centeredAt: point)
        publishZoom()
    }
}
struct ZoomedImageView: NSViewRepresentable {
    let image: NSImage
    let id: UUID
    @Binding var zoom: Double
    func makeNSView(context: Context) -> PinchImageScrollView { PinchImageScrollView() }
    func updateNSView(_ view: PinchImageScrollView, context: Context) {
        if view.representedID != id {
            view.representedID = id; view.imageView.image = image; view.needsLayout = true
        }
        let binding = $zoom
        view.onZoom = { value in if abs(binding.wrappedValue - value) > 0.001 { binding.wrappedValue = value } }
        view.setControlZoom(zoom)
    }
    static func dismantleNSView(_ view: PinchImageScrollView, coordinator: ()) {
        view.onZoom = nil; view.imageView.image = nil; view.documentView = nil
    }
}

struct ZoomedPDFView: NSViewRepresentable {
    let document: PDFDocument
    let id: UUID
    @Binding var zoom: Double
    func makeCoordinator() -> Coordinator { Coordinator($zoom) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.binding = $zoom
        coordinator.applying = true
        defer { coordinator.applying = false }
        if coordinator.documentID != id {
            coordinator.documentID = id
            view.document = document; view.autoScales = true
        }
        let fit = max(0.0001, view.scaleFactorForSizeToFit)
        let target = PreviewZoom.clamp(zoom)
        if target == 1 {
            if !view.autoScales { view.autoScales = true }
        } else if abs(view.scaleFactor / fit - target) > 0.002 {
            view.autoScales = false
            view.minScaleFactor = fit * PreviewZoom.minimum
            view.maxScaleFactor = fit * PreviewZoom.maximum
            view.scaleFactor = fit * target
        }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stop(); view.document = nil
    }
    @MainActor final class Coordinator {
        var binding: Binding<Double>
        var documentID: UUID?
        var applying = false
        private var observer: NSObjectProtocol?
        init(_ binding: Binding<Double>) { self.binding = binding }
        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let view, view.document != nil, !self.applying, self.documentID != nil else { return }
                    let fit = view.scaleFactorForSizeToFit
                    guard fit > 0 else { return }
                    let value = PreviewZoom.clamp(view.scaleFactor / fit)
                    if abs(self.binding.wrappedValue - value) > 0.002 { self.binding.wrappedValue = value }
                }
            }
        }
        func stop() { documentID = nil; if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

