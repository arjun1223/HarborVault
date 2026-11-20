import SwiftUI
import AppKit
import CoreText

enum HarborDesign {
    static let amber = Color(red: 0.92, green: 0.65, blue: 0.20)
    static let charcoal = Color(red: 0.15, green: 0.16, blue: 0.17)
    static let green = Color(red: 0.22, green: 0.49, blue: 0.36)
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let canvas = adaptive(light: NSColor(srgbRed: 0.972, green: 0.969, blue: 0.962, alpha: 1), dark: NSColor(srgbRed: 0.086, green: 0.089, blue: 0.095, alpha: 1))
    static let surface = adaptive(light: .white, dark: NSColor(white: 0.14, alpha: 1))
    static let sidebar = adaptive(light: NSColor(srgbRed: 0.935, green: 0.930, blue: 0.918, alpha: 1), dark: NSColor(srgbRed: 0.111, green: 0.114, blue: 0.122, alpha: 1))
    static let inset = adaptive(light: NSColor(white: 0.96, alpha: 1), dark: NSColor(white: 0.18, alpha: 1))
    static let selected = adaptive(light: NSColor(white: 0.89, alpha: 1), dark: NSColor(white: 0.23, alpha: 1))
    static let highlight = adaptive(light: NSColor(srgbRed: 0.956, green: 0.908, blue: 0.793, alpha: 1), dark: NSColor(srgbRed: 0.248, green: 0.205, blue: 0.132, alpha: 1))
    static let border = adaptive(light: NSColor(white: 0.88, alpha: 1), dark: NSColor(white: 0.26, alpha: 1))
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, scale: CGFloat = 1) -> Font {
        .custom("InstrumentSans-Regular", size: size * scale).weight(weight)
    }
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .semibold, scale: CGFloat = 1) -> Font {
        .custom("Manrope-Regular", size: size * scale).weight(weight)
    }
    static func registerFonts() {
        for name in ["InstrumentSans", "Manrope"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

enum HarborCredits {
    static let author = "Made by Arjun Tyagi"
    static let github = URL(string: "https://github.com/arjun1223")!
}
struct HarborButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @State private var hovering = false
    @Environment(\.harborGlass) private var glass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(HarborDesign.font(compact ? 12 : 13, .medium))
            .foregroundStyle(primary && (!glass || reduceTransparency) ? HarborDesign.charcoal : Color.primary)
            .padding(.horizontal, compact ? 12 : 16).frame(minHeight: compact ? 32 : 40)
            .harborChrome(radius: compact ? 10 : 12,
                          standard: primary ? HarborDesign.amber : HarborDesign.surface,
                          tint: primary ? HarborDesign.amber : .clear)
            .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 12)
                .strokeBorder(primary || (glass && !reduceTransparency) ? .clear : HarborDesign.border, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 12).fill(.primary.opacity(hovering && enabled ? 0.045 : 0)).allowsHitTesting(false))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.72 : 1)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct HarborField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(HarborDesign.font(13)).padding(.horizontal, 13).frame(height: 42)
            .background(HarborDesign.inset, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(HarborDesign.border, lineWidth: 1))
    }
}
extension View {
    func harborField() -> some View { modifier(HarborField()) }
    func harborSurface(radius: CGFloat = 16) -> some View {
        background(HarborDesign.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(HarborDesign.border, lineWidth: 1))
    }
}
extension Font {
    static func harbor(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if design == .monospaced { return .system(size: size, weight: weight, design: .monospaced) }
        if design == .rounded { return HarborDesign.heading(size, weight) }
        return HarborDesign.font(size, weight)
    }
}

struct PasswordEntry: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    init(_ title: String, text: Binding<String>) { self.title = title; _text = text }
    var body: some View {
        HStack(spacing: 9) {
            Group {
                if revealed { TextField(title, text: $text).focused($fieldFocused) }
                else { SecureField(title, text: $text).focused($fieldFocused) }
            }.textFieldStyle(.plain).autocorrectionDisabled()
            Button {
                revealed.toggle()
                fieldFocused = false
                DispatchQueue.main.async { fieldFocused = true }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24, height: 26)
            }.buttonStyle(.plain).help(revealed ? "Hide password" : "Show password")
                .accessibilityLabel(revealed ? "Hide password" : "Show password")
        }.onDisappear { revealed = false; fieldFocused = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
    }
}
