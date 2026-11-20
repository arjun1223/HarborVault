import SwiftUI
import AppKit

enum HarborGlassAvailability {
    static var supported: Bool {
        if #available(macOS 26, *) { return NSClassFromString("NSGlassEffectView") != nil }
        return false
    }
}

private struct HarborGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var harborGlass: Bool {
        get { self[HarborGlassKey.self] }
        set { self[HarborGlassKey.self] = newValue }
    }
}

extension View {
    func harborChrome(radius: CGFloat = 16, standard: Color, tint: Color = .clear) -> some View {
        modifier(HarborChrome(radius: radius, standard: standard, tint: tint))
    }
}

struct HarborBackdrop: View {
    @Environment(\.harborGlass) private var glass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if glass && !reduceTransparency {
                GlassWindowBackdrop()
                if #available(macOS 27, *) {
                    // The native material tracks the system Liquid Glass setting.
                    // The backing blur softens the windows visible through it.
                    Color.clear.harborChrome(radius: 16, standard: HarborDesign.canvas)
                } else {
                    HarborDesign.canvas.opacity(0.62)
                }
            } else {
                HarborDesign.canvas
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct GlassWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowBlurView {
        let view = WindowBlurView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }
    func updateNSView(_ view: WindowBlurView, context: Context) {}
    static func dismantleNSView(_ view: WindowBlurView, coordinator: ()) {
        view.restoreWindow()
    }
}

@MainActor
private final class WindowBlurView: NSVisualEffectView {
    private weak var styledWindow: NSWindow?
    private var previousColor: NSColor?
    private var previousOpacity = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard styledWindow !== window else { return }
        restoreWindow()
        guard let window else { return }
        styledWindow = window
        previousColor = window.backgroundColor
        previousOpacity = window.isOpaque
        window.backgroundColor = .clear
        window.isOpaque = false
        window.invalidateShadow()
    }

    func restoreWindow() {
        if let styledWindow {
            if let previousColor { styledWindow.backgroundColor = previousColor }
            styledWindow.isOpaque = previousOpacity
            styledWindow.invalidateShadow()
        }
        styledWindow = nil
        previousColor = nil
    }
}

private struct HarborChrome: ViewModifier {
    @Environment(\.harborGlass) private var glass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    let standard: Color
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass && !reduceTransparency {
            applyGlass(to: content)
        } else {
            content.background(standard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func applyGlass(to content: Content) -> some View {
        let glassRadius = radius == 0 ? 16 : radius
        let shape = RoundedRectangle(cornerRadius: glassRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint == .clear ? nil : tint), in: shape)
        } else {
            content.background(standard, in: shape)
        }
        #else
        if #available(macOS 26, *), let glassClass = NSClassFromString("NSGlassEffectView") {
            content.background {
                NativeGlassBackground(viewClass: glassClass, radius: glassRadius, tint: tint)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        } else {
            content.background(standard, in: shape)
        }
        #endif
    }
}

// The published AppKit glass view can be resolved at runtime while allowing
// Harbor Vault to build against an older SDK and run on macOS 14 and 15.
private struct NativeGlassBackground: NSViewRepresentable {
    let viewClass: AnyClass
    let radius: CGFloat
    let tint: Color

    func makeNSView(context: Context) -> NSView {
        let host = GlassBackgroundHost()
        let glassType: AnyObject = viewClass
        guard let glass = glassType.perform?(NSSelectorFromString("new"))?.takeRetainedValue() as? NSView else {
            return host
        }

        // AppKit uses the content view to lay out the glass surface.
        let plate = NSView(frame: host.bounds)
        plate.autoresizingMask = [.width, .height]
        if glass.responds(to: NSSelectorFromString("setContentView:")) {
            glass.setValue(plate, forKey: "contentView")
        }
        glass.frame = host.bounds
        glass.autoresizingMask = [.width, .height]
        host.addSubview(glass)
        applyStyle(to: glass)
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let glass = view.subviews.first { applyStyle(to: glass) }
    }

    private func applyStyle(to view: NSView) {
        if view.responds(to: NSSelectorFromString("setCornerRadius:")) {
            view.setValue(NSNumber(value: Double(radius)), forKey: "cornerRadius")
        }
        if view.responds(to: NSSelectorFromString("setTintColor:")) {
            view.setValue(tint == .clear ? nil : NSColor(tint), forKey: "tintColor")
        }
    }
}

private final class GlassBackgroundHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
