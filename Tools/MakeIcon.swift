import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let size = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let outer = NSBezierPath(roundedRect: NSRect(x: 72, y: 80, width: 880, height: 880), xRadius: 205, yRadius: 205)
    NSColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 1).setFill(); outer.fill()
    NSColor.white.withAlphaComponent(0.08).setStroke(); outer.lineWidth = 3; outer.stroke()
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 244, y: 688))
    folder.curve(to: NSPoint(x: 296, y: 740), controlPoint1: NSPoint(x: 244, y: 722), controlPoint2: NSPoint(x: 263, y: 740))
    folder.line(to: NSPoint(x: 444, y: 740))
    folder.curve(to: NSPoint(x: 506, y: 698), controlPoint1: NSPoint(x: 474, y: 740), controlPoint2: NSPoint(x: 480, y: 698))
    folder.line(to: NSPoint(x: 728, y: 698))
    folder.curve(to: NSPoint(x: 780, y: 646), controlPoint1: NSPoint(x: 761, y: 698), controlPoint2: NSPoint(x: 780, y: 678))
    folder.line(to: NSPoint(x: 780, y: 360))
    folder.curve(to: NSPoint(x: 728, y: 308), controlPoint1: NSPoint(x: 780, y: 327), controlPoint2: NSPoint(x: 761, y: 308))
    folder.line(to: NSPoint(x: 296, y: 308))
    folder.curve(to: NSPoint(x: 244, y: 360), controlPoint1: NSPoint(x: 263, y: 308), controlPoint2: NSPoint(x: 244, y: 327))
    folder.close()
    NSColor(srgbRed: 0.92, green: 0.65, blue: 0.20, alpha: 1).setFill(); folder.fill()
    NSColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 1).setStroke()
    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: 455, y: 516)); shackle.line(to: NSPoint(x: 455, y: 563))
    shackle.curve(to: NSPoint(x: 569, y: 563), controlPoint1: NSPoint(x: 455, y: 642), controlPoint2: NSPoint(x: 569, y: 642))
    shackle.line(to: NSPoint(x: 569, y: 516)); shackle.lineWidth = 26; shackle.lineCapStyle = .round; shackle.stroke()
    NSColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 429, y: 407, width: 166, height: 129), xRadius: 28, yRadius: 28).fill()
    NSColor(srgbRed: 0.92, green: 0.65, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 500, y: 469, width: 24, height: 24)).fill()
    NSBezierPath(roundedRect: NSRect(x: 506, y: 446, width: 12, height: 35), xRadius: 5, yRadius: 5).fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let path = "\(output)/icon_\(points)x\(points)\(suffix).png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
// Modern ICNS entries embed the PNG bytes directly; no GUI/icon service is needed.
func bigEndian(_ value: Int) -> Data { var n = UInt32(value).bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
var entries = Data()
for (code, filename) in [("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
                         ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
                         ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
                         ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
                         ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent(filename))
    entries.append(Data(code.utf8)); entries.append(bigEndian(png.count + 8)); entries.append(png)
}
try (Data("icns".utf8) + bigEndian(entries.count + 8) + entries).write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("icns"))
