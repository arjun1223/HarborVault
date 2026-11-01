import AppKit
import ImageIO
import CoreGraphics
import CoreText

enum ThumbnailRenderer {
    static func supports(_ name: String) -> Bool {
        ["png","jpg","jpeg","heic","heif","gif","tif","tiff","bmp","webp","pdf","txt","md","csv","json","log","swift","py","js","html","css","xml","yaml","yml","rtf"].contains((name as NSString).pathExtension.lowercased())
    }
    static func render(_ data: Data, name: String, pixels: Int = 512) -> NSImage? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf", let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1) {
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let scale = CGFloat(pixels) / max(box.width, box.height)
            let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
            guard let cg = context(width, height) else { return nil }
            cg.setFillColor(CGColor(gray: 1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            cg.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            cg.drawPDFPage(page)
            return cg.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        if data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            let width = pixels, height = Int(Double(pixels) * 1.28)
            guard let cg = context(width, height) else { return nil }
            cg.setFillColor(CGColor(gray: 1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Menlo" as CFString, CGFloat(pixels) / 30, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.22, alpha: 1)
            ]
            let string = NSAttributedString(string: String(text.prefix(2200)), attributes: attributes)
            let setter = CTFramesetterCreateWithAttributedString(string)
            let inset = CGFloat(pixels) * 0.085
            let rect = CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), cg)
            return cg.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
        }
        return nil
    }
    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

@MainActor final class ThumbnailCache {
    private let cache = NSCache<NSUUID, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private var pending: [UUID: [(NSImage?) -> Void]] = [:]
    private var unavailable: Set<UUID> = []
    private var session = UUID()
    init() { cache.totalCostLimit = 96 * 1024 * 1024; cache.countLimit = 240 }
    func request(_ item: VaultItem, load: @escaping @Sendable () throws -> Data, completion: @escaping (NSImage?) -> Void) {
        guard !item.isFolder, item.size <= 50 * 1024 * 1024, ThumbnailRenderer.supports(item.name) else { completion(nil); return }
        if let cached = cache.object(forKey: item.id as NSUUID) { completion(cached); return }
        if unavailable.contains(item.id) { completion(nil); return }
        if pending[item.id] != nil { pending[item.id]?.append(completion); return }
        pending[item.id] = [completion]
        let token = session
        let work = BlockOperation()
        work.addExecutionBlock { [weak work, weak self] in
            guard work?.isCancelled == false else { return }
            let image: NSImage? = autoreleasepool {
                guard let data = try? load(), work?.isCancelled == false else { return nil }
                return ThumbnailRenderer.render(data, name: item.name)
            }
            guard work?.isCancelled == false else { return }
            Task { @MainActor [weak self] in
                guard let self, self.session == token else { return }
                if let image { self.cache.setObject(image, forKey: item.id as NSUUID, cost: Int(image.size.width * image.size.height * 4)) }
                else { self.unavailable.insert(item.id) }
                let callbacks = self.pending.removeValue(forKey: item.id) ?? []
                callbacks.forEach { $0(image) }
            }
        }
        queue.addOperation(work)
    }
    func clear() {
        session = UUID(); queue.cancelAllOperations()
        pending = [:]; unavailable = []; cache.removeAllObjects()
    }
}

