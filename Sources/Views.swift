import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

private let accent = HarborDesign.amber
private let ink = Color.primary
private let panel = HarborDesign.surface

final class DropCollector: @unchecked Sendable {
    private let lock = NSLock(); private var values: [URL] = []
    func add(_ url: URL) { lock.lock(); defer { lock.unlock() }; values.append(url) }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
}

struct ItemMenu: View {
    @EnvironmentObject var model: AppModel
    let item: VaultItem
    var body: some View {
        Button(item.isFolder ? "Open folder" : "Preview") { model.open(item) }
        Button("Export decrypted copy…") { model.export(item) }
        Divider()
        Button("Rename…") { model.rename(item) }
        Menu("Move to") {
            Button("All files") { model.move(item, to: nil) }.disabled(item.parent == nil)
            ForEach(model.manifest.items.filter { $0.isFolder && $0.id != item.id }.sorted { $0.name < $1.name }) { folder in
                Button(folder.name) { model.move(item, to: folder.id) }.disabled(item.parent == folder.id)
            }
        }
        Divider()
        Button("Delete from vault…", role: .destructive) { model.delete(item) }
    }
}

struct CreateVaultView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = "Personal"
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var mac = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Create a vault", systemImage: "lock.shield").font(.harbor(size: 23, weight: .semibold, design: .rounded))
            Text("Each vault has its own passcode and encryption key.").font(.harbor(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Vault name").font(.harbor(size: 11, weight: .medium))
                TextField("e.g. Personal or Work", text: $name).harborField()
                Text("Vault names are visible while locked. Use a neutral name.").font(.harbor(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Vault passcode").font(.harbor(size: 11, weight: .medium))
                PasswordEntry("At least 10 characters", text: $passcode).harborField()
                PasswordEntry("Confirm passcode", text: $confirm).harborField()
                if !confirm.isEmpty && passcode != confirm { Text("Passcodes don’t match yet.").font(.harbor(size: 10)).foregroundStyle(.orange) }
            }
            Toggle(isOn: $mac) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also unlock with Touch ID / Mac password").font(.harbor(size: 12, weight: .medium))
                    Text("Anyone who can authenticate to your Mac can use this option. Turn it off for a passcode-only vault.").font(.harbor(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.checkbox)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "key").foregroundStyle(accent)
                Text("Keep your vault passcode safe. It’s your recovery if Mac unlock becomes unavailable or you move to a new Mac. There is no passcode reset.").font(.harbor(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(13).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if let error = model.error { Text(error).font(.harbor(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { model.showCreate = false }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Create vault") { let input = passcode; passcode = ""; confirm = ""; model.create(name: name, passcode: input, mac: mac) }.buttonStyle(HarborButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || passcode.count < 10 || passcode != confirm || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.plain).padding(32).frame(width: 490).background(HarborDesign.surface).interactiveDismissDisabled(model.busy)
    }
}

struct PasscodeSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var passcode = ""
    @State private var confirm = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Change vault passcode").font(.harbor(size: 21, weight: .semibold, design: .rounded))
            Text("This changes the passcode for \(model.header?.name ?? "this vault") only.").font(.harbor(size: 12)).foregroundStyle(.secondary)
            PasswordEntry("New passcode · at least 10 characters", text: $passcode).harborField()
            PasswordEntry("Confirm new passcode", text: $confirm).harborField()
            Text("The previous passcode will stop working. Keep the new one safe—there’s no reset.").font(.harbor(size: 11)).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.harbor(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Button("Cancel") { model.showPasscodeSettings = false }.disabled(model.busy); Spacer(); Button("Update passcode") { let input = passcode; passcode = ""; confirm = ""; model.changePasscode(input) }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy || passcode.count < 10 || passcode != confirm) }
        }.textFieldStyle(.plain).padding(32).frame(width: 460).background(HarborDesign.surface).interactiveDismissDisabled(model.busy)
    }
}

struct ImportSheetItem: Identifiable {
    var id: UUID { result.receipts.first?.id ?? UUID() }
    let result: ImportResult
}
struct ImportCompleteView: View {
    @EnvironmentObject var model: AppModel
    let result: ImportResult
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.harbor(size: 28)).foregroundStyle(HarborDesign.green)
            Text("Import complete").font(.harbor(size: 22, weight: .semibold, design: .rounded))
            Text("\(result.importedFiles) file\(result.importedFiles == 1 ? "" : "s") saved inside your vault. You can now move the original items to Trash.").font(.harbor(size: 12)).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 7) { ForEach(result.receipts) { receipt in Label(receipt.source.lastPathComponent, systemImage: "checkmark.circle").font(.harbor(size: 11)).lineLimit(1) } } }.frame(maxHeight: 110)
            Text("Items in Trash are still readable until you empty it. Other copies, cloud versions, and backups are separate.").font(.harbor(size: 11)).foregroundStyle(.secondary).padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack { Button("Keep originals") { model.importResult = nil }; Spacer(); Button("Move originals to Trash") { model.trashOriginals(result) }.buttonStyle(HarborButtonStyle(primary: true)) }
        }.padding(32).frame(width: 490).background(HarborDesign.surface)
    }
}

struct PreviewView: View {
    @EnvironmentObject var model: AppModel
    let content: PreviewContent
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: content.item.symbol).foregroundStyle(accent); Text(content.item.name).font(.harbor(size: 13, weight: .medium)).lineLimit(1); Spacer(); Button("Done") { model.preview = nil }.keyboardShortcut(.cancelAction) }.padding(18)
            Divider()
            Group {
                if (content.item.name as NSString).pathExtension.lowercased() == "pdf", let doc = PDFDocument(data: content.data) {
                    MemoryPDFView(document: doc)
                } else if let image = NSImage(data: content.data) {
                    Image(nsImage: image).resizable().scaledToFit().padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if content.data.count <= 2 * 1024 * 1024, let text = String(data: content.data, encoding: .utf8), !text.contains("\0") {
                    ScrollView([.vertical, .horizontal]) { Text(text).font(.harbor(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(22) }
                } else {
                    VStack(spacing: 16) { Image(systemName: "doc").font(.harbor(size: 46, weight: .light)).foregroundStyle(.secondary); Text("No in-app preview for this format").font(.harbor(size: 16, weight: .medium)); Text("Export a copy to open it in another app.").foregroundStyle(.secondary); Button("Export decrypted copy…") { model.preview = nil; model.export(content.item) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Label("Preview stays in memory. Export creates a readable copy outside the vault.", systemImage: "lock.shield").font(.harbor(size: 10)).foregroundStyle(.secondary).padding(12)
        }.frame(width: 740, height: 560)
    }
}
struct MemoryPDFView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = document; view.displaysPageBreaks = true; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
    static func dismantleNSView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
