import SwiftUI
import AppKit
import UniformTypeIdentifiers

private typealias D = HarborDesign

struct RootView: View {
    @EnvironmentObject var model: AppModel
    private var scheme: ColorScheme? { model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                SidebarView().frame(width: geometry.size.width < 1040 ? 212 : 236)
                Rectangle().fill(D.border).frame(width: 1)
                VStack(spacing: 0) {
                    HeaderView()
                    Rectangle().fill(D.border).frame(height: 1)
                    if model.unlocked { BrowserView() } else { LockedView().id(model.selectedVaultID) }
                    StatusBar()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 640).background(D.canvas).tint(D.amber)
        .font(D.font(13, scale: model.textScale)).preferredColorScheme(scheme)
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
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain).accessibilityLabel("Dismiss notification")
                }.padding(16).harborSurface(radius: 14).shadow(color: .black.opacity(0.05), radius: 12, y: 4).frame(maxWidth: 640).padding(.bottom, 50).padding(.horizontal, 28)
            }
        }
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
                    Text("Private file storage").font(D.font(10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.top, 38).padding(.bottom, 32)
            Button { if model.unlocked { model.showRecentlyDeleted(false) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 14, weight: .medium))
                    Text("Files").font(D.font(13, .semibold, scale: model.textScale))
                    Spacer()
                    if model.unlocked { Text("\(model.fileCount)").font(D.font(11)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 13).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).background(model.viewingRecentlyDeleted ? .clear : D.selected.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14)
            Button { model.showRecentlyDeleted(true) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 14))
                    Text("Recently Deleted").font(D.font(12, .medium, scale: model.textScale))
                    Spacer(minLength: 2)
                    if model.unlocked { Text("\(model.trashCount)").font(D.font(11)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 13).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.unlocked)
                .background(model.viewingRecentlyDeleted ? D.selected.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14).padding(.top, 4)
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
                            .contextMenu {
                                Button("Rename vault…") { model.renameVault(vault) }.disabled(model.busy || !model.unlocked || model.selectedVaultID != vault.id)
                                Button("Delete vault…", role: .destructive) { model.beginDeleteVault(vault) }.disabled(model.busy)
                            }
                    }
                }.padding(.horizontal, 14)
            }
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive").font(.system(size: 14)).foregroundStyle(.secondary)
                    Text("Stored on this Mac").font(D.font(11, .medium))
                }
                Text("Files stay encrypted while locked.").font(D.font(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(D.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 13)).padding(.horizontal, 16).padding(.bottom, 17)
            Rectangle().fill(D.border).frame(height: 1).padding(.horizontal, 21)
            Button { model.showSettings = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                    Text("Preferences").font(D.font(12))
                    Spacer()
                    Text("⌘,").font(D.font(11)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.background(D.sidebar)
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
            .padding(.horizontal, 30).frame(height: 108).background(D.surface)
    }
    private func header(compact: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.viewingRecentlyDeleted ? "Recently Deleted" : "Files").font(D.heading(25, .semibold, scale: model.textScale)).tracking(-0.7)
                Text(model.header?.name ?? "Create a vault to get started").font(D.font(12, scale: model.textScale)).foregroundStyle(.secondary).lineLimit(1)
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
                Text("Auto-lock after \(model.idleMinutes) min").foregroundStyle(.tertiary)
            }.font(D.font(10)).foregroundStyle(.secondary).padding(.horizontal, 28).frame(height: 36).background(D.surface)
        }
    }
}

struct LockedView: View {
    @EnvironmentObject var model: AppModel
    @State private var passcode = ""
    @State private var usePasscode = false
    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 19).fill(D.inset).frame(width: 66, height: 66)
                    Image(systemName: "folder.fill").font(.system(size: 28)).foregroundStyle(D.amber).frame(width: 66, height: 66)
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(6).background(D.surface, in: Circle()).overlay(Circle().strokeBorder(D.border, lineWidth: 1)).offset(x: 5, y: 4)
                }.padding(.bottom, 28)
                Text(model.header == nil ? "Your private workspace" : "Unlock your vault").font(D.heading(25, .semibold, scale: model.textScale)).tracking(-0.7).padding(.bottom, 10)
                Text(model.header == nil ? "Keep private files organized in separate encrypted vaults." : "Authenticate to browse and manage the files in this vault.")
                    .font(D.font(13, scale: model.textScale)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.bottom, 27)
                if model.header == nil {
                    Button { model.showCreate = true } label: { HStack { Image(systemName: "plus"); Text("Create a vault"); Spacer(); Image(systemName: "arrow.right") }.frame(maxWidth: .infinity) }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy || model.storage == nil)
                } else {
                    if model.header?.macUnlock != nil {
                        Button { passcode = ""; model.unlockMac() } label: {
                            HStack(spacing: 9) { Image(systemName: "touchid").font(.system(size: 18)); Text("Unlock with your Mac"); Spacer(); Image(systemName: "arrow.right").font(.system(size: 12)) }.frame(maxWidth: .infinity)
                        }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy)
                        Text("Touch ID or Mac login password").font(D.font(10)).foregroundStyle(.secondary).padding(.top, 9)
                        Button { usePasscode.toggle() } label: {
                            HStack { Text("Use vault passcode"); Spacer(); Image(systemName: usePasscode ? "chevron.up" : "chevron.down").font(.system(size: 10)) }.font(D.font(12)).contentShape(Rectangle()).padding(.vertical, 15)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    if usePasscode || model.header?.macUnlock == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            PasswordEntry("Vault passcode", text: $passcode).harborField().onSubmit(submit)
                            Button(action: submit) { HStack { Text("Unlock vault"); Spacer(); Image(systemName: "arrow.right") }.frame(maxWidth: .infinity) }.buttonStyle(HarborButtonStyle(primary: model.header?.macUnlock == nil)).disabled(passcode.isEmpty || model.busy)
                        }
                    }
                }
                Rectangle().fill(D.border).frame(height: 1).padding(.top, 24).padding(.bottom, 17)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 12)).padding(.top, 1)
                    Text("File contents and filenames stay encrypted while locked.").font(D.font(11)).lineSpacing(3)
                }.foregroundStyle(.secondary)
            }.padding(32).frame(width: 416).harborSurface(radius: 22)
            HStack(spacing: 6) { Image(systemName: "internaldrive"); Text("Stored locally. No cloud account required.") }.font(D.font(10)).foregroundStyle(.tertiary)
            Spacer(minLength: 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func submit() { guard !passcode.isEmpty, !model.busy else { return }; let input = passcode; passcode = ""; model.unlock(passcode: input) }
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTarget = false
    private var rowHeight: CGFloat { (model.density == "compact" ? 43 : 58) * model.textScale }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 25, height: 26) }.buttonStyle(.plain).disabled(!model.canGoBack).help("Back (⌘[)")
                    Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 25, height: 26) }.buttonStyle(.plain).disabled(!model.canGoForward).help("Forward (⌘])")
                }.padding(.trailing, 10)
                Button { if !model.viewingRecentlyDeleted { model.navigate(nil) } } label: { Image(systemName: model.viewingRecentlyDeleted ? "trash" : "folder"); Text(model.viewingRecentlyDeleted ? "Recently Deleted" : "All files") }.buttonStyle(.plain)
                ForEach(model.crumbs) { item in
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Button(item.name) { model.navigate(item.id) }.buttonStyle(.plain).lineLimit(1)
                }
                Spacer()
                if !model.query.isEmpty { Text("\(model.visible.count) result\(model.visible.count == 1 ? "" : "s")").foregroundStyle(.secondary) }
            }.font(D.font(12, .medium, scale: model.textScale)).padding(.bottom, 21)
            ViewThatFits(in: .horizontal) { toolbar(compact: false); toolbar(compact: true) }.padding(.bottom, 22)
            if model.viewingRecentlyDeleted { TrashRetentionBar().padding(.bottom, 16) }
            if model.visible.isEmpty { emptyState }
            else if model.grid { gridView }
            else { tableView }
            HStack(spacing: 9) {
                if model.selectionIDs.isEmpty { Text("Shift/⌘-click to select · Space for Quick View") }
                else { Text("\(model.selectionIDs.count) selected · Space for Quick View") }
                Spacer(minLength: 8)
                if model.grid {
                    Image(systemName: "photo").font(.system(size: 10))
                    Slider(value: $model.thumbnailSize, in: 80...224, step: 8).frame(width: 120).help("Thumbnail size").accessibilityLabel("Thumbnail size")
                    Image(systemName: "photo").font(.system(size: 15))
                }
            }.font(D.font(10)).foregroundStyle(.secondary).padding(.top, 16)
        }.padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 18).strokeBorder(D.amber, style: StrokeStyle(lineWidth: 2, dash: [7])).background(D.amber.opacity(0.04), in: RoundedRectangle(cornerRadius: 18)).padding(12).allowsHitTesting(false) } }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget, perform: receiveDrop)
    }
    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search filenames", text: Binding(get: { model.query }, set: { model.query = $0; model.searchChanged() })).textFieldStyle(.plain).font(D.font(12, scale: model.textScale))
                if !model.query.isEmpty { Button { model.query = ""; model.searchChanged() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 13).frame(width: compact ? 180 : 238, height: 36).background(D.surface, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(D.border, lineWidth: 1))
            Spacer(minLength: 8)
            HStack(spacing: 2) { viewButton(grid: false, symbol: "list.bullet", label: "List view"); viewButton(grid: true, symbol: "square.grid.2x2", label: "Grid view") }.padding(3).background(D.inset, in: RoundedRectangle(cornerRadius: 11))
            if model.viewingRecentlyDeleted {
                Button { model.restoreSelection() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.buttonStyle(HarborButtonStyle(primary: true, compact: true)).disabled(model.busy || model.selectionIDs.isEmpty)
                Button { model.editDeletionDate() } label: { HStack(spacing: 6) { Image(systemName: "calendar"); if !compact { Text("Change date") } } }.buttonStyle(HarborButtonStyle(compact: true)).disabled(model.busy || model.selectionIDs.isEmpty)
                Button { model.permanentlyDeleteSelection(all: true) } label: { Text("Empty…").foregroundStyle(.red) }.buttonStyle(HarborButtonStyle(compact: true)).disabled(model.busy || model.trashCount == 0)
            } else {
                Button { model.beginTransfer() } label: { Image(systemName: "arrow.right.square") }.buttonStyle(HarborButtonStyle(compact: true)).help("Send to another vault · move or duplicate").disabled(model.busy || model.selectionIDs.isEmpty)
                Button { model.beginShare() } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(HarborButtonStyle(compact: true)).help("Share selected files · requires verification").disabled(model.busy || model.selectionIDs.isEmpty)
                Button { model.newFolder() } label: { HStack(spacing: 6) { Image(systemName: "folder.badge.plus"); if !compact { Text("New folder") } } }.buttonStyle(HarborButtonStyle(compact: true)).help("New folder (⇧⌘N)").disabled(model.busy)
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
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Kind").frame(width: 85, alignment: .leading)
                Text("Size").frame(width: 74, alignment: .trailing)
                Text(model.viewingRecentlyDeleted ? "Deletes on" : "Date added").frame(width: 74, alignment: .trailing)
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
            Text(model.query.isEmpty ? model.viewingRecentlyDeleted ? "Deleted items from this vault stay here until restored or permanently removed." : "Import files or drop a folder into this window.\nYour originals stay put until you choose to remove them." : "Search looks at filenames and folder names in this vault.")
                .font(D.font(12, scale: model.textScale)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            if model.query.isEmpty && !model.viewingRecentlyDeleted { Button { model.pickImport() } label: { Label("Import files", systemImage: "plus") }.buttonStyle(HarborButtonStyle(primary: true)).padding(.top, 9).disabled(model.busy) }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).harborSurface(radius: 17)
    }
    private func fileIcon(_ item: VaultItem, small: Bool) -> some View {
        Image(systemName: item.symbol).font(.system(size: small ? 17 : 24)).foregroundStyle(item.isFolder ? D.amber : Color.secondary)
            .frame(width: small ? 32 : 46, height: small ? 32 : 46).background(item.isFolder ? D.amber.opacity(0.10) : D.inset, in: RoundedRectangle(cornerRadius: small ? 9 : 13))
    }
    private func kind(_ item: VaultItem) -> String { item.isFolder ? "Folder" : (item.name as NSString).pathExtension.isEmpty ? "File" : (item.name as NSString).pathExtension.uppercased() + " file" }
    private func path(for item: VaultItem) -> String {
        var names: [String] = []; var id = item.parent
        while let current = id, let parent = model.manifest.items.first(where: { $0.id == current }) { names.insert(parent.name, at: 0); id = parent.parent }
        return names.isEmpty ? "All files" : names.joined(separator: " / ")
    }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, model.unlocked, !model.viewingRecentlyDeleted else { return false }
        let group = DispatchGroup(); let collector = DropCollector()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                defer { group.leave() }
                if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(url) }
                else if let url = value as? URL { collector.add(url) }
            }
        }
        let vaultID = model.selectedVaultID
        group.notify(queue: .main) { if model.unlocked, model.selectedVaultID == vaultID { model.importFiles(collector.urls) } }
        return true
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
            HStack { Text("Changes save automatically.").font(D.font(10)).foregroundStyle(.tertiary); Spacer(); Button("Done") { model.showSettings = false }.buttonStyle(HarborButtonStyle(primary: true)) }.padding(.top, 5)
        }.padding(32).frame(width: 570).background(D.surface).preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "dark" ? .dark : .light)
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

