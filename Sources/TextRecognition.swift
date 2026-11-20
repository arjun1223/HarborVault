import Foundation
import Vision
import CoreGraphics
import ImageIO

struct RecognizedPage: Sendable, Equatable {
    let number: Int
    let text: String
}
struct RecognizedDocument: Sendable, Equatable {
    let pages: [RecognizedPage]
    var text: String {
        if pages.count == 1 { return pages[0].text }
        return pages.map { "Page \($0.number)\n\($0.text)" }.joined(separator: "\n\n")
    }
    var isEmpty: Bool { pages.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

final class TextRecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var current: VNRequest?
    func cancel() {
        lock.lock(); cancelled = true; let request = current; lock.unlock()
        request?.cancel()
    }
    func check() throws {
        try Task.checkCancellation()
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func attach(_ request: VNRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        current = request
    }
    func detach() { lock.lock(); current = nil; lock.unlock() }
}

enum TextRecognition {
    static let rasterLimit = 3072
    static let pageLimit = 500
    static func supports(_ content: PreviewContent) -> Bool {
        guard !content.item.isFolder, content.video == nil else { return false }
        if (content.item.name as NSString).pathExtension.lowercased() == "pdf" { return true }
        guard let source = CGImageSourceCreateWithData(content.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }
    static func recognize(_ content: PreviewContent, cancellation: TextRecognitionCancellation = TextRecognitionCancellation(), progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> RecognizedDocument {
        try cancellation.check()
        guard !content.item.isFolder else { throw VaultError.message("Choose an image or PDF to recognize text.") }
        if (content.item.name as NSString).pathExtension.lowercased() == "pdf" {
            guard let provider = CGDataProvider(data: content.data as CFData), let pdf = CGPDFDocument(provider) else { throw VaultError.message("This PDF could not be read for text recognition.") }
            guard pdf.isUnlocked else { throw VaultError.message("Unlock this password-protected PDF before recognizing its text.") }
            guard pdf.numberOfPages > 0, pdf.numberOfPages <= pageLimit else { throw VaultError.message("Text recognition supports PDFs with 1–\(pageLimit) pages.") }
            var pages: [RecognizedPage] = []
            for number in 1...pdf.numberOfPages {
                try cancellation.check(); progress(number, pdf.numberOfPages)
                let text = try autoreleasepool {
                    guard let page = pdf.page(at: number) else { throw VaultError.message("PDF page \(number) could not be read.") }
                    return try recognizeImage(render(page), cancellation: cancellation)
                }
                pages.append(RecognizedPage(number: number, text: text))
            }
            return RecognizedDocument(pages: pages)
        }
        guard let source = CGImageSourceCreateWithData(content.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else { throw VaultError.message("Text recognition supports images and PDFs.") }
        progress(1, 1)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: rasterLimit,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw VaultError.message("The image could not be read for text recognition.") }
        let text = try recognizeImage(image, cancellation: cancellation)
        return RecognizedDocument(pages: [RecognizedPage(number: 1, text: text)])
    }
    private static func render(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { throw VaultError.message("This PDF page has an invalid size.") }
        let scale = CGFloat(rasterLimit) / max(box.width, box.height)
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VaultError.message("This PDF page could not be prepared for text recognition.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw VaultError.message("This PDF page could not be rendered.") }
        return image
    }
    private static func recognizeImage(_ image: CGImage, cancellation: TextRecognitionCancellation) throws -> String {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.preferBackgroundProcessing = true
        try cancellation.attach(request)
        defer { cancellation.detach() }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw error }
        try cancellation.check()
        return (request.results ?? []).sorted {
            $0.boundingBox.maxY == $1.boundingBox.maxY ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.maxY > $1.boundingBox.maxY
        }.compactMap { $0.topCandidates(1).first?.string }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
