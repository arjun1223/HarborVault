import SwiftUI

struct TrashDateRequest: Identifiable {
    let id = UUID()
    let items: [VaultItem]
    var automatic: Bool { items.contains { $0.permanentDeletionDate != nil } }
    var date: Date { items.compactMap(\.permanentDeletionDate).min() ?? Calendar.current.date(byAdding: .day, value: 30, to: Date())! }
}

struct TrashDateView: View {
    @EnvironmentObject var model: AppModel
    let request: TrashDateRequest
    @State private var date: Date
    @State private var automatic: Bool
    private typealias D = HarborDesign
    init(request: TrashDateRequest) {
        self.request = request
        _date = State(initialValue: max(request.date, Date().addingTimeInterval(60)))
        _automatic = State(initialValue: request.automatic)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Permanent-deletion date").font(D.heading(23, .semibold))
            Text("Set when these \(request.items.count) deleted item\(request.items.count == 1 ? "" : "s") should stop being recoverable in this vault.")
                .font(D.font(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Automatically delete on a date", isOn: $automatic).toggleStyle(.checkbox).font(D.font(12, .medium))
            if automatic {
                DatePicker("Delete after", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.field).font(D.font(12))
            }
            Text(automatic
                 ? "Expired copies are permanently removed while this vault is unlocked, or on its next unlock. You can restore them or extend the date before cleanup."
                 : "These encrypted copies will stay in Recently Deleted until you restore or permanently delete them yourself.")
                .font(D.font(11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(14).background(D.inset, in: RoundedRectangle(cornerRadius: 12))
            if let error = model.error { Text(error).font(D.font(11)).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.trashDateEdit = nil }.buttonStyle(HarborButtonStyle()).keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save date") { model.saveDeletionDate(automatic ? date : nil, request: request) }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy)
            }
        }.padding(32).frame(width: 490).background(D.surface).interactiveDismissDisabled(model.busy)
    }
}

struct TrashRetentionBar: View {
    @EnvironmentObject var model: AppModel
    private typealias D = HarborDesign
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("Keep future deleted items").font(D.font(12, .medium))
                Spacer()
                Menu {
                    ForEach([7, 30, 60, 90, 365, 0], id: \.self) { days in
                        Button { model.setTrashRetention(days) } label: {
                            if model.manifest.retentionDays == days { Label(days == 0 ? "Until I delete them" : "\(days) days", systemImage: "checkmark") }
                            else { Text(days == 0 ? "Until I delete them" : "\(days) days") }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.manifest.retentionDays == 0 ? "Until I delete them" : "\(model.manifest.retentionDays) days")
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.font(D.font(12)).foregroundStyle(.primary).padding(.horizontal, 12).frame(height: 33)
                        .background(D.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(D.border, lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy)
            }
            Text("This setting belongs to this vault. Existing deletion dates stay as set; select an item and choose “Change date” to edit its date.")
                .font(D.font(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).harborSurface(radius: 14)
    }
}


struct RestoreRequest: Identifiable {
    let id = UUID()
    let items: [VaultItem]
}

struct RestoreItemsView: View {
    @EnvironmentObject var model: AppModel
    let request: RestoreRequest
    @State private var original = true
    @State private var destination: UUID?
    private typealias D = HarborDesign
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(request.items.count == 1 ? "Restore this file?" : "Restore these \(request.items.count) items?").font(D.heading(23, .semibold))
            if request.items.count == 1 { Text(request.items[0].name).font(D.font(13, .medium)).lineLimit(2) }
            Toggle("Restore \(request.items.count == 1 ? "this file" : "these items") to \(request.items.count == 1 ? "its" : "their") prior location", isOn: $original)
                .toggleStyle(.checkbox).font(D.font(12, .medium))
            if original {
                Text("Returns to the previous folder inside this vault. If that folder no longer exists, the item returns to All files. Existing files are never overwritten.")
                    .font(D.font(11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Button { original = false } label: { Label("Choose other location…", systemImage: "folder") }.buttonStyle(.plain).font(D.font(12)).foregroundStyle(.primary)
            if !original {
                Menu {
                    Button("All files") { destination = nil }
                    ForEach(model.manifest.items.filter { $0.isFolder && !$0.isDeleted }.sorted { model.pathForFolder($0.id) < model.pathForFolder($1.id) }) { folder in
                        Button(model.pathForFolder(folder.id)) { destination = folder.id }
                    }
                } label: {
                    HStack { Image(systemName: "folder"); Text(model.pathForFolder(destination)).lineLimit(1); Spacer(); Image(systemName: "chevron.down").font(.system(size: 10)) }
                        .font(D.font(12)).foregroundStyle(.primary).padding(13).frame(maxWidth: .infinity)
                        .background(D.inset, in: RoundedRectangle(cornerRadius: 11))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            }
            if let error = model.error { Text(error).font(D.font(11)).foregroundStyle(.red) }
            HStack {
                Button("No") { model.restoreRequest = nil }.buttonStyle(HarborButtonStyle()).keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Restore") { model.confirmRestore(request, destination: original ? .original : .folder(destination)) }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy)
            }
        }.padding(32).frame(width: 490).background(D.surface).interactiveDismissDisabled(model.busy)
    }
}

