import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct HarborVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        HarborDesign.registerFonts()
        let args = CommandLine.arguments
        let testRoot: URL? = args.firstIndex(of: "--test-root").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        _model = StateObject(wrappedValue: AppModel(root: testRoot))
    }
    var body: some Scene {
        Window("Harbor Vault", id: "main") {
            RootView().environmentObject(model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.lock() }
        }.defaultSize(width: 1160, height: 760).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New vault…") { model.showCreate = true }.keyboardShortcut("n").disabled(model.busy || model.storage == nil)
                    Button("New folder…") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.unlocked || model.busy || model.viewingRecentlyDeleted)
                    Button("Import files…") { model.pickImport() }.keyboardShortcut("i").disabled(!model.unlocked || model.busy || model.viewingRecentlyDeleted)
                    Button(model.viewingRecentlyDeleted ? "Delete Permanently…" : "Move to Recently Deleted…") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: [.command]).disabled(!model.unlocked || model.busy || model.selectionIDs.isEmpty)
                }
                CommandMenu("Vault") {
                    Button("Lock vault") { model.lock() }.keyboardShortcut("l").disabled(!model.unlocked && !model.busy)
                    Button("Quick View selection") { model.toggleQuickView() }.keyboardShortcut("o").disabled(!model.unlocked || model.selectedItem == nil || model.busy)
                    Button("Export selection…") { model.exportSelection() }.keyboardShortcut("e").disabled(!model.unlocked || model.selectionIDs.isEmpty || model.busy)
                    Button("Share selection… (verify identity)") { model.beginShare() }.disabled(!model.unlocked || model.selectionIDs.isEmpty || model.busy)
                    Button("Send to another vault…") { model.beginTransfer() }.disabled(!model.unlocked || model.selectionIDs.isEmpty || model.busy || model.viewingRecentlyDeleted)
                    Button("Recently Deleted") { model.showRecentlyDeleted(true) }.disabled(!model.unlocked || model.busy)
                    Divider()
                    Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.unlocked || !model.canGoBack)
                    Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.unlocked || !model.canGoForward)
                    Button("Enclosing folder") { model.goUp() }.keyboardShortcut(.upArrow, modifiers: [.command]).disabled(!model.unlocked || model.folderID == nil)
                    Divider()
                    Button("Change vault passcode…") { model.showPasscodeSettings = true }.disabled(!model.unlocked || model.busy)
                    Button("Rename vault…") { if let header = model.header { model.renameVault(header) } }.disabled(!model.unlocked || model.busy)
                    Button("Show encrypted storage in Finder") { if let root = model.storage?.root { NSWorkspace.shared.open(root) } }
                    Divider()
                    Button("Delete vault…", role: .destructive) { if let header = model.header { model.beginDeleteVault(header) } }.disabled(model.header == nil || model.busy)
                }
                CommandGroup(replacing: .help) {
                    Button("Harbor Vault guide") { if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) } }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Appearance & preferences…") { model.showSettings = true }.keyboardShortcut(",")
                }
            }
    }
}
