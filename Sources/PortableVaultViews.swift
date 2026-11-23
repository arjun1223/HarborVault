import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PortableImportView: View {
    @EnvironmentObject var model: AppModel
    let request: PortableImportRequest
    @State private var sharingKey = ""
    @State private var name = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var mac = true
    @State private var savedKeyURL: URL?
    @State private var savedKeyPassword = ""
    @State private var keyError: String?
    @State private var allowPreviouslyImported = false
    @State private var isPublic = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Open portable vault", systemImage: "shippingbox").font(HarborDesign.heading(23, .semibold))
            Text(request.url.lastPathComponent).font(HarborDesign.font(12)).foregroundStyle(.secondary).lineLimit(2)
            if isPublic {
                Label("Public copy · no sharing key needed", systemImage: "globe").font(HarborDesign.font(13))
            } else {
                PasswordEntry("HARB sharing key", text: $sharingKey).harborField()
                Button("Load saved key…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.begin { response in if response == .OK { savedKeyURL = panel.url } }
                }.disabled(model.busy)
                if let savedKeyURL {
                    PasswordEntry("Saved-key password", text: $savedKeyPassword).harborField()
                    Button("Unlock saved key") {
                        do {
                            sharingKey = try ProtectedSharingKey.load(from: savedKeyURL, password: savedKeyPassword)
                            savedKeyPassword = ""; self.savedKeyURL = nil; keyError = nil
                        } catch { keyError = error.localizedDescription }
                    }.disabled(savedKeyPassword.isEmpty || model.busy)
                }
                if let keyError { Text(keyError).font(HarborDesign.font(11)).foregroundStyle(.red) }
            }
            Text(isPublic ? "Anyone can read the exported file. Choose a password to protect your own imported copy on this Mac." : "Use the sharing key sent by the owner. Choose a password to protect your own imported copy.")
                .font(HarborDesign.font(12)).foregroundStyle(.secondary)
            TextField("Vault name (optional)", text: $name).harborField()
            PasswordEntry("New vault password", text: $password).harborField()
            PasswordEntry("Confirm vault password", text: $confirmation).harborField()
            Toggle("Also unlock with Touch ID / Mac password", isOn: $mac).font(HarborDesign.font(12))
            Toggle("Import another or older copy", isOn: $allowPreviouslyImported).font(HarborDesign.font(12))
            if let error = model.error { Text(error).font(HarborDesign.font(12)).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.portableImport = nil; model.error = nil }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Import vault") {
                    model.importPortable(request, sharingKey: sharingKey, name: name, passcode: password, mac: mac, allowPreviouslyImported: allowPreviouslyImported)
                }.buttonStyle(HarborButtonStyle(primary: true))
                    .disabled(model.busy || (!isPublic && sharingKey.isEmpty) || password.count < 10 || password != confirmation)
            }
        }.padding(28).frame(width: 470).background(HarborDesign.surface)
            .interactiveDismissDisabled(model.busy)
            .onAppear {
                do { isPublic = try PortableVault.isPublic(request.url) }
                catch { model.error = error.localizedDescription }
            }
            .onDisappear { sharingKey = ""; password = ""; confirmation = ""; savedKeyPassword = "" }
    }
}

struct PortableExportView: View {
    @EnvironmentObject var model: AppModel
    let receipt: PortableExportReceipt
    @State private var savedKey = false
    @State private var message: String?
    @State private var savingKey = false
    @State private var keyPassword = ""
    @State private var keyConfirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(receipt.isPublic ? "Public vault exported" : "Portable vault exported", systemImage: receipt.isPublic ? "globe" : "checkmark.shield").font(HarborDesign.heading(23, .semibold))
            Text(receipt.url.lastPathComponent).font(HarborDesign.font(12)).foregroundStyle(.secondary).lineLimit(2)
            if receipt.isPublic {
                Text("Anyone with this file can view and download its contents. No key or password is needed, and shared copies cannot be recalled.").font(HarborDesign.font(13))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([receipt.url]) }
            } else {
                Text("Save this sharing key. Anyone with the .harb file and this key can open the exported copy.")
                    .font(HarborDesign.font(13))
                Text(receipt.sharingKey).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(14).harborSurface(radius: 12)
                HStack {
                    Button("Copy key") {
                        SecretClipboard.copy(receipt.sharingKey)
                        message = "Key copied. Harbor clears its clipboard entry after 60 seconds or when the vault locks."
                    }
                    Button("Save protected key…") { savingKey.toggle() }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([receipt.url]) }
                }
                if savingKey {
                    PasswordEntry("Password for saved key", text: $keyPassword).harborField()
                    PasswordEntry("Confirm saved-key password", text: $keyConfirmation).harborField()
                    Button("Save encrypted key file…") { saveKey() }
                        .disabled(keyPassword.count < 10 || keyPassword != keyConfirmation)
                }
                Text("Send the key separately. Imported copies are independent and access cannot be revoked.")
                    .font(HarborDesign.font(12)).foregroundStyle(.secondary)
                if let message { Text(message).font(HarborDesign.font(12)).foregroundStyle(.secondary) }
                Toggle("I saved the sharing key", isOn: $savedKey).font(HarborDesign.font(12))
            }
            HStack { Spacer(); Button("Done") { model.portableExport = nil }.buttonStyle(HarborButtonStyle(primary: true)).disabled(!receipt.isPublic && !savedKey) }
        }.padding(28).frame(width: 500).background(HarborDesign.surface).interactiveDismissDisabled(true)
            .onDisappear { keyPassword = ""; keyConfirmation = "" }
    }
    private func saveKey() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = receipt.url.deletingPathExtension().lastPathComponent + ".harbkey"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard model.portableExport?.id == receipt.id else { return }
                guard url.resolvingSymlinksInPath().standardizedFileURL != receipt.url.resolvingSymlinksInPath().standardizedFileURL else { throw VaultError.message("Choose a different file for the saved key.") }
                try ProtectedSharingKey.save(receipt.sharingKey, password: keyPassword, to: url)
                savedKey = true
                keyPassword = ""; keyConfirmation = ""; savingKey = false
                message = "Encrypted sharing key saved. Keep its password separately."
            } catch { message = error.localizedDescription }
        }
    }
}
