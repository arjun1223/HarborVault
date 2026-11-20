import AppKit

enum DragActionAppearance {
    static func draw(_ action: DragQuickAction, in bounds: NSRect, highlighted: Bool) {
        let accent: NSColor = action == .trash ? .systemRed : .controlAccentColor
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 26, yRadius: 26)
        (highlighted ? accent.withAlphaComponent(0.18) : NSColor.clear).setFill()
        card.fill()
        (highlighted ? accent.withAlphaComponent(0.8) : NSColor.separatorColor.withAlphaComponent(0.4)).setStroke()
        card.lineWidth = highlighted ? 1.5 : 1
        card.stroke()

        let iconRect = NSRect(x: 18, y: bounds.midY - 14, width: 28, height: 28)
        if action == .trash {
            drawTrash(in: iconRect, color: highlighted ? accent : .secondaryLabelColor, open: highlighted)
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
                .applying(.init(paletteColors: [highlighted ? accent : .labelColor]))
            if let icon = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let scale = min(iconRect.width / max(1, icon.size.width),
                                iconRect.height / max(1, icon.size.height))
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                let fitted = NSRect(x: iconRect.midX - size.width / 2, y: iconRect.midY - size.height / 2,
                                    width: size.width, height: size.height)
                icon.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let title: String
        let detail: String
        switch action {
        case .trash: title = "Trash"; detail = "Recently Deleted"
        case .share: title = "Share"; detail = "Verify identity"
        case .export: title = "Export"; detail = "Choose destination"
        case .root: title = "All files"; detail = "Move to vault root"
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 62, y: bounds.midY - 19, width: bounds.width - 72, height: 21),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                             .foregroundColor: highlighted ? accent : NSColor.labelColor, .paragraphStyle: paragraph])
        (detail as NSString).draw(in: NSRect(x: 62, y: bounds.midY + 6, width: bounds.width - 72, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph])
    }

    private static func drawTrash(in rect: NSRect, color: NSColor, open: Bool) {
        color.setStroke()
        let x = rect.midX
        let y = rect.minY
        let body = NSBezierPath()
        body.move(to: NSPoint(x: x - 8, y: y + 9))
        body.line(to: NSPoint(x: x - 6, y: y + 25))
        body.line(to: NSPoint(x: x + 6, y: y + 25))
        body.line(to: NSPoint(x: x + 8, y: y + 9))
        body.move(to: NSPoint(x: x - 3, y: y + 12))
        body.line(to: NSPoint(x: x - 2, y: y + 21))
        body.move(to: NSPoint(x: x + 3, y: y + 12))
        body.line(to: NSPoint(x: x + 2, y: y + 21))
        body.lineWidth = 1.6
        body.lineJoinStyle = .round
        body.stroke()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: x, yBy: y + (open ? 3 : 6))
        transform.concat()
        if open {
            let rotation = NSAffineTransform()
            rotation.rotate(byDegrees: -18)
            rotation.concat()
        }
        let lid = NSBezierPath()
        lid.move(to: NSPoint(x: -11, y: 0)); lid.line(to: NSPoint(x: 11, y: 0))
        lid.move(to: NSPoint(x: -3, y: 0)); lid.line(to: NSPoint(x: -3, y: -3))
        lid.line(to: NSPoint(x: 3, y: -3)); lid.line(to: NSPoint(x: 3, y: 0))
        lid.lineWidth = 1.6
        lid.lineCapStyle = .round
        lid.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
