import SwiftUI
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import UniformTypeIdentifiers

private typealias D = HarborDesign

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var model: AppModel
    private var scheme: ColorScheme? { model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    if model.internalDragIDs.isEmpty { SidebarView().transition(.opacity) }
                    else { DragActionsSidebar().transition(.opacity) }
                }
                .frame(width: geometry.size.width < 1040 ? 206 : 226)
                .animation(.easeInOut(duration: 0.18), value: model.internalDragIDs.isEmpty)
                Rectangle().fill(D.border).frame(width: 1)
                VStack(spacing: 0) {
                    HeaderView()
                    Rectangle().fill(D.border).frame(height: 1)
                    if model.unlocked { BrowserView() } else { LockedView().id(model.selectedVaultID) }
                    StatusBar()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 850, minHeight: 600).background { HarborBackdrop() }.tint(D.amber)
        .font(D.font(13, scale: model.textScale)).preferredColorScheme(scheme)
        .task(id: scenePhase == .active && model.canStartAutomaticMacUnlock) {
            if scenePhase == .active && model.canStartAutomaticMacUnlock { model.beginAutomaticMacUnlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.cancelInlineTouchID() }
        }
        .sheet(isPresented: $model.showCreate) { CreateVaultView() }
        .sheet(isPresented: $model.showPasscodeSettings) { PasscodeSettingsView() }
        .sheet(isPresented: $model.showSettings) { PreferencesView() }
        .sheet(item: $model.protectedAction) { ProtectedActionView(request: $0) }
        .sheet(item: $model.trashDateEdit) { TrashDateView(request: $0) }
        .sheet(item: $model.restoreRequest) { RestoreItemsView(request: $0) }
        .sheet(item: $model.transferRequest) { VaultTransferView(request: $0) }
        .sheet(item: Binding(get: { model.importResult.map(ImportSheetItem.init) }, set: { if $0 == nil { model.importResult = nil } })) { ImportCompleteView(result: $0.result) }
        .alert("Harbor Vault", isPresented: Binding(get: { model.error != nil && !model.showCreate && !model.showPasscodeSettings && model.protectedAction == nil && model.trashDateEdit == nil && model.restoreRequest == nil && model.transferRequest == nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(D.green)
                    Text(notice).font(D.font(12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let exported = model.noticeExportURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }
                            .buttonStyle(HarborButtonStyle(compact: true))
                            .fixedSize()
                    }
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain).accessibilityLabel("Dismiss notification")
                }.padding(16).harborSurface(radius: 14).shadow(color: .black.opacity(0.05), radius: 12, y: 4).frame(maxWidth: 640).padding(.bottom, 50).padding(.horizontal, 28)
            }
        }
        .environment(\.harborGlass, model.liquidGlass && HarborGlassAvailability.supported)
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(D.charcoal).frame(width: 38, height: 38)
                    Image(systemName: "folder.fill").font(.system(size: 19, weight: .medium)).foregroundStyle(D.amber)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Harbor").font(D.heading(21, .bold)).tracking(-0.6)
                    Text("Vault").font(D.font(12, .medium)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.top, 40).padding(.bottom, 25)
            Button { model.showRecentlyDeleted(false) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 14, weight: .medium))
                    Text("Files").font(D.font(13, .semibold, scale: model.textScale))
                    Spacer()
                    if model.unlocked { Text("\(model.fileCount)").font(D.font(11)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 13).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.unlocked).background(model.unlocked && !model.viewingRecentlyDeleted ? D.highlight : .clear, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14)
            Button { model.showRecentlyDeleted(true) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 14))
                    Text("Recently Deleted").font(D.font(12, .medium, scale: model.textScale))
                    Spacer(minLength: 2)
                    if model.unlocked { Text("\(model.trashCount)").font(D.font(11)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 13).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.unlocked)
                .background(model.viewingRecentlyDeleted ? D.highlight : .clear, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14).padding(.top, 4)
            HStack {
                Text("VAULTS").font(D.font(10, .semibold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Button { model.showCreate = true } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain).help("Create a vault").disabled(model.busy || model.storage == nil)
            }.padding(.horizontal, 25).padding(.top, 32).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.vaults) { vault in
                        Button { model.choose(vault.id) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "externaldrive").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 20)
                                Text(vault.name).font(D.font(12, model.selectedVaultID == vault.id ? .medium : .regular, scale: model.textScale)).lineLimit(1)
                                Spacer(minLength: 2)
                                if model.selectedVaultID == vault.id && model.unlocked {
                                    Circle().fill(D.green).frame(width: 6, height: 6).accessibilityLabel("Unlocked")
                                } else { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary) }
                            }.padding(.horizontal, 12).frame(height: model.density == "compact" ? 37 : 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(model.selectedVaultID == vault.id ? D.surface : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(model.selectedVaultID == vault.id ? D.border.opacity(0.65) : .clear, lineWidth: 1))
                            .disabled(model.busy)
                            .contextMenu {
                                Button("Rename vault…") { model.renameVault(vault) }.disabled(model.busy || !model.unlocked || model.selectedVaultID != vault.id)
                                Button("Delete vault…", role: .destructive) { model.beginDeleteVault(vault) }.disabled(model.busy)
                            }
                    }
                }.padding(.horizontal, 14)
            }
            Spacer(minLength: 18)
            Rectangle().fill(D.border).frame(height: 1).padding(.horizontal, 21)
            Button { model.showSettings = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                    Text("Preferences").font(D.font(12))
                    Spacer()
                    Text("⌘,").font(D.font(11)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.harborChrome(radius: 0, standard: D.sidebar)
    }
}

struct VaultStatus: View {
    let unlocked: Bool
    var body: some View {
        HStack(spacing: 6) {
            if unlocked { Circle().fill(D.green).frame(width: 5, height: 5) }
            else { Image(systemName: "lock.fill").font(.system(size: 9)) }
            Text(unlocked ? "Unlocked" : "Locked").font(D.font(11, .medium))
        }.foregroundStyle(unlocked ? D.green : Color.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            .background(unlocked ? D.green.opacity(0.08) : D.inset, in: Capsule())
    }
}

struct HeaderView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ViewThatFits(in: .horizontal) { header(compact: false); header(compact: true) }
            .padding(.horizontal, 26).padding(.top, 16).frame(height: 91).harborChrome(radius: 0, standard: D.surface)
    }
    private func header(compact: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.header?.name ?? "Harbor Vault").font(D.heading(25, .bold, scale: model.textScale)).tracking(-0.8).lineLimit(1)
                if model.unlocked {
                    Text(model.viewingRecentlyDeleted ? "Recently Deleted" : "Files").font(D.font(12, scale: model.textScale)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 18)
            if model.header != nil { VaultStatus(unlocked: model.unlocked) }
            if model.unlocked {
                Menu {
                    Button("Rename vault…") { if let header = model.header { model.renameVault(header) } }
                    Button("Change vault passcode…") { model.showPasscodeSettings = true }
                    Button(model.header?.macUnlock == nil ? "Enable Touch ID / Mac password" : "Require vault passcode only") { model.toggleMacUnlock() }
                } label: { Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 20, height: 24) }.menuStyle(.borderlessButton).tint(.primary).fixedSize().disabled(model.busy).help("Vault options")
                Button { model.lock() } label: { Label("Lock", systemImage: "lock") }.buttonStyle(HarborButtonStyle(compact: true)).help("Lock vault (⌘L)")
            } else {
                Button { model.showCreate = true } label: { HStack(spacing: 7) { Image(systemName: "plus"); if !compact { Text("New vault") } } }
                    .buttonStyle(HarborButtonStyle(compact: true)).disabled(model.busy || model.storage == nil)
            }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(D.border).frame(height: 1)
            HStack(spacing: 7) {
                if model.busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: model.unlocked ? "checkmark.shield" : "lock").font(.system(size: 10)) }
                Text(model.busy ? model.activity : model.unlocked ? model.viewingRecentlyDeleted ? "\(model.trashCount) deleted items · \(ByteCountFormatter.string(fromByteCount: model.trashBytes, countStyle: .file))" : "\(model.fileCount) file\(model.fileCount == 1 ? "" : "s")  ·  \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))" : "Vault contents are encrypted")
                Spacer()
                Label("Auto-lock · \(model.idleMinutes) min", systemImage: "timer").foregroundStyle(.secondary)
            }.font(D.font(10)).foregroundStyle(.secondary).padding(.horizontal, 28).frame(height: 31).harborChrome(radius: 0, standard: D.surface)
        }
    }
}

struct LockedView: View {
    @EnvironmentObject var model: AppModel
    @State private var passcode = ""
    @State private var usePasscode = false

    private var macEnabled: Bool { model.header?.macUnlock != nil }

    private var instruction: String {
        if model.busy { return model.activity }
        if let message = model.inlineTouchIDMessage { return message }
        if model.inlineTouchIDContext != nil { return "Touch ID or enter a password to continue." }
        if !macEnabled || usePasscode { return "Enter your vault passcode to continue." }
        return "Use Touch ID or enter a password to continue."
    }

    var body: some View {
        VStack(spacing: 0) {
            lockIcon.padding(.bottom, 16)
            if let header = model.header {
                Text("\(header.name) is locked")
                    .font(D.heading(23, .semibold, scale: model.textScale))
                    .lineLimit(2)
                    .help(header.name)
                Text(instruction)
                    .font(D.font(14, scale: model.textScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                unlockControls.padding(.top, 18)
            } else {
                Text("Your private workspace").font(D.heading(23, .semibold, scale: model.textScale))
                Text("Keep private files in separate encrypted vaults.")
                    .foregroundStyle(.secondary).padding(.top, 5)
                Button("Create a vault") { model.showCreate = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.storage == nil)
                    .padding(.top, 18)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var lockIcon: some View {
        let badgeSize: CGFloat = 44
        return ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 72, height: 72)
            if model.protectedAction == nil, let context = model.inlineTouchIDContext {
                InlineTouchIDView(context: context, ready: model.evaluateInlineTouchID)
                    .id(ObjectIdentifier(context))
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                    .clipShape(Circle())
                    .offset(x: 4, y: 3)
            } else {
                Image(systemName: macEnabled ? "touchid" : "lock.fill")
                    .font(.system(size: macEnabled ? 24 : 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                    .offset(x: 4, y: 3)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var unlockControls: some View {
        if macEnabled {
            VStack(spacing: 10) {
                if model.busy {
                    if model.activity == "Waiting for Mac authentication…" {
                        Button("Cancel") { model.lock() }.keyboardShortcut(.cancelAction)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button {
                        usePasscode.toggle()
                        if usePasscode { model.pauseInlineTouchID() }
                        else { passcode = ""; model.prepareInlineTouchID() }
                    } label: {
                        Text(usePasscode ? "Hide Vault Password" : "Use Vault Password…").frame(width: 190)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.primary)

                    HStack(spacing: 14) {
                        if model.inlineTouchIDContext != nil {
                            Button("Cancel Touch ID") { model.pauseInlineTouchID() }
                                .keyboardShortcut(.cancelAction)
                        } else {
                            Button("Use Touch ID") {
                                passcode = ""; usePasscode = false; model.prepareInlineTouchID()
                            }
                        }
                        Button("Use Mac Password…") {
                            passcode = ""; usePasscode = false; model.unlockMac()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(D.font(11, scale: model.textScale))
                }
            }
        }
        if usePasscode || !macEnabled {
            VStack(spacing: 10) {
                PasswordEntry("Vault passcode", text: $passcode).harborField().onSubmit(submit)
                Button("Unlock vault", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(passcode.isEmpty || model.busy)
            }
            .frame(maxWidth: 250)
            .padding(.top, macEnabled ? 12 : 0)
        }
    }

    private func submit() {
        guard !passcode.isEmpty, !model.busy else { return }
        let input = passcode
        passcode = ""
        model.unlock(passcode: input)
    }
}

struct InlineTouchIDView: NSViewRepresentable {
    let context: LAContext
    let ready: (LAContext) -> Void

    func makeNSView(context representableContext: Context) -> TouchIDHost {
        TouchIDHost(authenticationContext: context, ready: ready)
    }

    func updateNSView(_ view: TouchIDHost, context: Context) {}

    final class TouchIDHost: NSView {
        private let authenticationView: LAAuthenticationView
        private var ready: ((LAContext) -> Void)?
        private var keyObserver: NSObjectProtocol?

        init(authenticationContext: LAContext, ready: @escaping (LAContext) -> Void) {
            authenticationView = LAAuthenticationView(context: authenticationContext, controlSize: .small)
            self.ready = ready
            super.init(frame: .zero)
            authenticationView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(authenticationView)
            NSLayoutConstraint.activate([
                authenticationView.leadingAnchor.constraint(equalTo: leadingAnchor),
                authenticationView.trailingAnchor.constraint(equalTo: trailingAnchor),
                authenticationView.topAnchor.constraint(equalTo: topAnchor),
                authenticationView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(authenticationContext:ready:)") }

        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
            guard let window else { return }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.startWhenReady() }
            }
            DispatchQueue.main.async { [weak self] in self?.startWhenReady() }
        }

        private func startWhenReady() {
            guard let window, window.isKeyWindow, window.isVisible, let ready else { return }
            self.ready = nil
            ready(authenticationView.context)
        }
    }
}

struct BreadcrumbButton: NSViewRepresentable {
    let model: AppModel
    let folder: UUID?
    let title: String
    var symbol: String? = nil

    func makeNSView(context: Context) -> BreadcrumbNativeButton {
        let button = BreadcrumbNativeButton()
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.target = button
        button.action = #selector(BreadcrumbNativeButton.openFolder)
        button.registerForDraggedTypes([FileCollectionView.vaultDragType])
        return button
    }

    func updateNSView(_ button: BreadcrumbNativeButton, context: Context) {
        button.model = model
        button.folder = folder
        button.title = title
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        button.font = NSFont.systemFont(ofSize: 12 * model.textScale, weight: .medium)
        button.contentTintColor = .labelColor
        button.toolTip = "Drop here to move to " + title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreadcrumbNativeButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: min(size.width + 12, proposal.width ?? size.width + 12), height: max(28, size.height))
    }
}

enum DragQuickAction: String, CaseIterable {
    case trash = "Move to Trash"
    case share = "Share…"
    case export = "Export…"
    case root = "Move to All Files"
    var symbol: String {
        switch self {
        case .trash: return "trash"
        case .share: return "square.and.arrow.up"
        case .export: return "square.and.arrow.down"
        case .root: return "folder"
        }
    }
}

private struct DragActionsSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick actions").font(D.heading(17, .semibold)).padding(.top, 22)
            Text("\(model.internalDragIDs.count) selected").font(D.font(12)).foregroundStyle(.secondary)
                .padding(.bottom, 12)
            ForEach(DragQuickAction.allCases, id: \.self) { action in
                DragActionButton(model: model, action: action)
                    .frame(height: 86)
                    .harborChrome(radius: 26, standard: D.surface)
            }
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .harborChrome(radius: 0, standard: D.sidebar)
    }
}

private struct DragActionButton: NSViewRepresentable {
    let model: AppModel
    let action: DragQuickAction
    func makeNSView(context: Context) -> BreadcrumbNativeButton {
        let button = BreadcrumbNativeButton()
        button.quickAction = action
        button.title = action == .trash ? "" : action.rawValue
        button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.registerForDraggedTypes([FileCollectionView.vaultDragType])
        button.setAccessibilityLabel(action.rawValue)
        return button
    }
    func updateNSView(_ button: BreadcrumbNativeButton, context: Context) { button.model = model }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreadcrumbNativeButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 186, height: proposal.height ?? 86)
    }
}

@MainActor final class BreadcrumbNativeButton: NSButton {
    weak var model: AppModel?
    var folder: UUID?
    var quickAction: DragQuickAction?
    private var dropHighlighted = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { quickAction != nil ? true : super.isFlipped }
    override func draw(_ dirtyRect: NSRect) {
        if let quickAction {
            DragActionAppearance.draw(quickAction, in: bounds, highlighted: dropHighlighted)
        } else {
            super.draw(dirtyRect)
        }
    }

    @objc func openFolder() {
        guard let model, !model.viewingRecentlyDeleted else { return }
        model.navigate(folder)
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? FileItemCanvas,
              let sourceModel = source.browser?.model, let model, sourceModel === model else { return false }
        return model.canDropSelection(in: folder)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = accepts(sender)
        highlight(allowed)
        dropHighlighted = allowed
        return allowed ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight(false)
        dropHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        dropHighlighted = false
        guard accepts(sender) else { return false }
        if let quickAction, let model {
            let ids = model.internalDragIDs
            let vaultID = model.selectedVaultID
            // Run after AppKit finishes the drag so dialogs can receive focus.
            DispatchQueue.main.async { [weak model] in
                guard let model, model.unlocked, !model.busy, model.selectedVaultID == vaultID,
                      ids.isSubset(of: Set(model.visible.map(\.id))) else { return }
                model.setSelection(ids)
                switch quickAction {
                case .trash: model.deleteSelection(confirm: false)
                case .share: model.beginShare()
                case .export: model.exportSelection()
                case .root: model.moveSelection(to: nil)
                }
            }
            return true
        }
        return model?.dropSelection(in: folder) == true
    }
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTarget = false
    @FocusState private var searchFocused: Bool
    private var sort: Binding<FileSort> { model.viewingRecentlyDeleted ? $model.trashSort : $model.fileSort }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 25, height: 26) }.buttonStyle(.plain).disabled(!model.canGoBack).help("Back (⌘[)")
                    Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 25, height: 26) }.buttonStyle(.plain).disabled(!model.canGoForward).help("Forward (⌘])")
                }.padding(.trailing, 10)
                BreadcrumbButton(model: model, folder: nil,
                                 title: model.viewingRecentlyDeleted ? "Recently Deleted" : "All files",
                                 symbol: model.viewingRecentlyDeleted ? "trash" : "folder")
                    .fixedSize()
                ForEach(model.crumbs) { item in
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    BreadcrumbButton(model: model, folder: item.id, title: item.name)
                }
                Spacer()
                if !model.query.isEmpty { Text("\(model.visible.count) result\(model.visible.count == 1 ? "" : "s")").foregroundStyle(.secondary) }
            }.font(D.font(12, .medium, scale: model.textScale)).padding(.bottom, 12)
            ViewThatFits(in: .horizontal) { toolbar(compact: false); toolbar(compact: true) }.padding(.bottom, 14)
            if model.viewingRecentlyDeleted { TrashRetentionBar().padding(.bottom, 16) }
            NativeDropRegion(model: model, targeted: $dropTarget) {
                if model.visible.isEmpty { emptyState }
                else if model.grid { gridView }
                else { tableView }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 9) {
                if model.selectionIDs.isEmpty { Text("\(model.visible.count) item\(model.visible.count == 1 ? "" : "s")") }
                else { Text("\(model.selectionIDs.count) selected · Space for Quick View") }
                Spacer(minLength: 8)
                if model.grid {
                    Image(systemName: "photo").font(.system(size: 10))
                    Slider(value: $model.thumbnailSize, in: 80...224, step: 8).frame(width: 120).help("Thumbnail size").accessibilityLabel("Thumbnail size")
                    Image(systemName: "photo").font(.system(size: 15))
                }
            }.font(D.font(10)).foregroundStyle(.secondary).padding(.top, 16)
        }.padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dropTarget {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(D.amber, style: StrokeStyle(lineWidth: 2, dash: [7]))
                        .background(D.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 18)).padding(12)
                        .overlay(alignment: .bottom) {
                            Label("Drop to import", systemImage: "arrow.down.to.line")
                                .font(D.font(12, .semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                                .background(D.amber, in: Capsule()).foregroundStyle(D.charcoal).padding(25)
                        }.allowsHitTesting(false)
                }
            }
    }
    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut("f").help("Search filenames (⌘F)").accessibilityLabel("Focus search")
                TextField("Search filenames", text: Binding(get: { model.query }, set: { model.query = $0; model.searchChanged() }))
                    .textFieldStyle(.plain).font(D.font(12, scale: model.textScale)).focused($searchFocused)
                if !model.query.isEmpty { Button { model.query = ""; model.searchChanged() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 13).frame(width: compact ? 146 : 217, height: 36).harborChrome(radius: 11, standard: D.surface).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(D.border, lineWidth: 1))
            Spacer(minLength: 8)
            HStack(spacing: 2) { viewButton(grid: false, symbol: "list.bullet", label: "List view"); viewButton(grid: true, symbol: "square.grid.2x2", label: "Grid view") }.padding(3).background(D.inset, in: RoundedRectangle(cornerRadius: 11))
            Menu {
                Picker("Sort by", selection: sort) {
                    ForEach(FileSort.allCases.filter { model.viewingRecentlyDeleted || $0 != .deletion }) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 19, height: 27) }
                .menuStyle(.borderlessButton).fixedSize().help("Sort files").accessibilityLabel("Sort files")
            if model.viewingRecentlyDeleted {
                Button { model.restoreSelection() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.buttonStyle(HarborButtonStyle(primary: true, compact: true)).disabled(model.busy || model.selectionIDs.isEmpty)
                Button { model.editDeletionDate() } label: { HStack(spacing: 6) { Image(systemName: "calendar"); if !compact { Text("Change date") } } }.buttonStyle(HarborButtonStyle(compact: true)).disabled(model.busy || model.selectionIDs.isEmpty)
                Button { model.permanentlyDeleteSelection(all: true) } label: { Text("Empty…").foregroundStyle(.red) }.buttonStyle(HarborButtonStyle(compact: true)).disabled(model.busy || model.trashCount == 0)
            } else {
                Menu {
                    Button { model.newFolder() } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        .disabled(model.busy)
                    Divider()
                    Button { model.beginShare() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        .disabled(model.busy || model.selectionIDs.isEmpty)
                    Button { model.beginTransfer() } label: { Label("Send to another vault…", systemImage: "arrow.right.square") }
                        .disabled(model.busy || model.selectionIDs.isEmpty)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)).frame(height: 27) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("File actions")
                Button { model.pickImport() } label: { Label("Import", systemImage: "plus") }.buttonStyle(HarborButtonStyle(primary: true, compact: true)).disabled(model.busy)
            }
        }
    }
    private func viewButton(grid: Bool, symbol: String, label: String) -> some View {
        Button { model.grid = grid } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 30, height: 27).foregroundStyle(model.grid == grid ? Color.primary : Color.secondary).background(model.grid == grid ? D.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private var tableView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sortColumn("Name", order: .name).frame(maxWidth: .infinity, alignment: .leading)
                sortColumn("Kind", order: .kind).frame(width: 85, alignment: .leading)
                sortColumn("Size", order: .largest).frame(width: 74, alignment: .trailing)
                sortColumn(model.viewingRecentlyDeleted ? "Deletes on" : "Date added", order: model.viewingRecentlyDeleted ? .deletion : .newest)
                    .frame(width: 82, alignment: .trailing)
            }.font(D.font(11, .medium, scale: model.textScale)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 41).background(D.inset.opacity(0.6))
            Divider()
            NativeFileBrowser(model: model)
        }.clipShape(RoundedRectangle(cornerRadius: 16)).harborSurface(radius: 16)
    }
    private var gridView: some View {
        NativeFileBrowser(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: model.query.isEmpty ? model.viewingRecentlyDeleted ? "trash" : "folder.badge.plus" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary).padding(.bottom, 5)
            Text(model.query.isEmpty ? model.viewingRecentlyDeleted ? "No recently deleted items" : "No files here yet" : "No matching files").font(D.heading(19, .semibold, scale: model.textScale)).tracking(-0.4)
            Text(model.query.isEmpty ? model.viewingRecentlyDeleted ? "Deleted items from this vault stay here until restored or permanently removed." : "Drop files, folders, or a screenshot thumbnail here.\nFinder originals stay put until you choose to remove them." : "Search looks at filenames and folder names in this vault.")
                .font(D.font(12, scale: model.textScale)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            if model.query.isEmpty && !model.viewingRecentlyDeleted { Button { model.pickImport() } label: { Label("Import files", systemImage: "plus") }.buttonStyle(HarborButtonStyle(primary: true)).padding(.top, 9).disabled(model.busy) }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).harborSurface(radius: 17)
    }
    private func sortColumn(_ label: String, order: FileSort) -> some View {
        Button { sort.wrappedValue = order } label: {
            HStack(spacing: 4) {
                Text(label)
                if sort.wrappedValue == order {
                    Image(systemName: order == .newest || order == .largest ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
        }.buttonStyle(.plain).help("Sort by \(order.rawValue.lowercased())")
    }
}

struct PreferencesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferences").font(D.heading(23, .semibold)).tracking(-0.6)
                    Text("Make the workspace feel right for you.").font(D.font(12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showSettings = false } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 26, height: 26).background(D.inset, in: Circle()) }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close preferences")
            }
            VStack(alignment: .leading, spacing: 14) {
                preferenceLabel("Appearance", detail: "Choose a light or charcoal workspace.")
                HStack(spacing: 10) { themeOption("light", title: "Light"); themeOption("dark", title: "Dark"); themeOption("system", title: "System") }
                HStack {
                    preferenceLabel("Liquid Glass", detail: liquidGlassDescription)
                    Spacer()
                    Toggle("Liquid Glass", isOn: $model.liquidGlass).labelsHidden().toggleStyle(.switch)
                        .disabled(!HarborGlassAvailability.supported)
                }
            }
            Rectangle().fill(D.border).frame(height: 1)
            HStack {
                preferenceLabel("Text size", detail: "Adjust file labels and interface text.")
                Spacer()
                Picker("Text size", selection: $model.textSize) { Text("Small").tag("small"); Text("Standard").tag("standard"); Text("Large").tag("large") }.labelsHidden().pickerStyle(.segmented).frame(width: 214)
            }
            HStack {
                preferenceLabel("Density", detail: "Choose how much fits on screen.")
                Spacer()
                Picker("Density", selection: $model.density) { Text("Compact").tag("compact"); Text("Comfortable").tag("comfortable") }.labelsHidden().pickerStyle(.segmented).frame(width: 214)
            }
            Rectangle().fill(D.border).frame(height: 1)
            HStack {
                preferenceLabel("Auto-lock", detail: "Also locks on sleep and screen lock.")
                Spacer()
                Menu {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Button { model.setIdle(minutes) } label: {
                            if minutes == model.idleMinutes { Label("\(minutes) minute\(minutes == 1 ? "" : "s")", systemImage: "checkmark") }
                            else { Text("\(minutes) minute\(minutes == 1 ? "" : "s")") }
                        }
                    }
                } label: {
                    HStack { Text("\(model.idleMinutes) minute\(model.idleMinutes == 1 ? "" : "s")"); Spacer(); Image(systemName: "chevron.down").font(.system(size: 9)) }
                        .font(D.font(12)).foregroundStyle(.primary).padding(.horizontal, 12).frame(width: 130, height: 34)
                        .background(D.inset, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(D.border, lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Auto-lock")
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(HarborCredits.author).font(D.font(12, .medium))
                    Link(destination: HarborCredits.github) {
                        Label("GitHub · arjun1223", systemImage: "arrow.up.right")
                            .font(D.font(11))
                    }
                    .help(HarborCredits.github.absoluteString)
                }
                Spacer()
                Button("Done") { model.showSettings = false }.buttonStyle(HarborButtonStyle(primary: true))
            }.padding(.top, 5)
        }.padding(32).frame(width: 570).background { HarborBackdrop() }.preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
    }
    private var liquidGlassDescription: String {
        guard HarborGlassAvailability.supported else { return "Requires macOS 26 or later." }
        if #available(macOS 27, *) { return "Glass intensity follows macOS System Settings." }
        return "Apple’s glass controls and a softly blurred window."
    }
    private func preferenceLabel(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(D.font(12, .medium)); Text(detail).font(D.font(10)).foregroundStyle(.secondary) } }
    private func themeOption(_ value: String, title: String) -> some View {
        Button { model.appearance = value } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3).fill(value == "dark" ? Color(white: 0.26) : Color(white: 0.88)).frame(width: 25)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(value == "dark" ? Color(white: 0.42) : Color(white: 0.79)).frame(width: 50, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(D.amber).frame(width: 32, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(value == "dark" ? Color(white: 0.35) : Color(white: 0.87)).frame(height: 15)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(value == "dark" ? Color(white: 0.17) : .white)
                }.frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(D.border, lineWidth: 1))
                HStack { Text(title).font(D.font(11, .medium)); Spacer(); Image(systemName: model.appearance == value ? "checkmark.circle.fill" : "circle").font(.system(size: 12)).foregroundStyle(model.appearance == value ? D.amber : D.border) }
            }.padding(10).background(D.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.appearance == value ? D.amber : D.border, lineWidth: model.appearance == value ? 1.5 : 1))
        }.buttonStyle(.plain).accessibilityLabel("\(title) appearance")
    }
}

