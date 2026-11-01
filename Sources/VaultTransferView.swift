import SwiftUI

struct VaultTransferView: View {
    @EnvironmentObject var model: AppModel
    let request: VaultTransferRequest
    @State private var mode: VaultTransferMode = .move
    @State private var passcode = ""
    private typealias D = HarborDesign
    private var destination: VaultHeader? { model.vaults.first { $0.id == model.transferDestinationID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            Text("Send to another vault").font(D.heading(23, .semibold))
            Text("\(request.items.count) selected item\(request.items.count == 1 ? "" : "s") from “\(request.source.name)”")
                .font(D.font(12)).foregroundStyle(.secondary)
            Picker("Destination vault", selection: Binding(get: { model.transferDestinationID }, set: { id in
                passcode = ""; if let id { model.selectTransferDestination(id) }
            })) {
                ForEach(model.vaults.filter { $0.id != request.source.id }) { vault in Text(vault.name).tag(Optional(vault.id)) }
            }.disabled(model.busy)
            VStack(alignment: .leading, spacing: 12) {
                Picker("What would you like to do?", selection: $mode) {
                    Text("Move · one copy total").tag(VaultTransferMode.move)
                    Text("Duplicate · keep both").tag(VaultTransferMode.duplicate)
                }.pickerStyle(.radioGroup)
                Text(mode == .move
                     ? "Keep one copy in the destination vault. The source is removed only after the destination copy is encrypted, saved, and verified."
                     : "Keep the original in this vault and create an independent encrypted copy in the destination vault.")
                    .font(D.font(11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Text("Files arrive in All files in the destination vault. Folder contents stay together.")
                    .font(D.font(11)).foregroundStyle(.secondary)
            }.padding(16).background(D.inset, in: RoundedRectangle(cornerRadius: 14))
            if model.transferAuthenticated {
                Label("Destination verified · valid for 60 seconds", systemImage: "checkmark.circle.fill").font(D.font(11, .medium)).foregroundStyle(D.green)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Verify the destination vault").font(D.font(12, .medium))
                    if destination?.macUnlock != nil {
                        Button { passcode = ""; model.authenticateTransferDestination(useMac: true) } label: {
                            Label("Touch ID / Mac password", systemImage: "touchid").frame(maxWidth: .infinity)
                        }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy)
                    }
                    HStack(spacing: 9) {
                        PasswordEntry("Destination vault’s passcode", text: $passcode).harborField().onSubmit(verify)
                        Button("Verify", action: verify).buttonStyle(HarborButtonStyle()).disabled(passcode.isEmpty || model.busy)
                    }
                }
            }
            if let error = model.error { Text(error).font(D.font(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { passcode = ""; model.cancelTransfer() }.buttonStyle(HarborButtonStyle()).keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(mode == .move ? "Move" : "Duplicate") { model.confirmTransfer(mode: mode) }
                    .buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy || !model.transferAuthenticated)
            }
        }.padding(32).frame(width: 530).background(D.surface).interactiveDismissDisabled(true)
    }
    private func verify() {
        guard !passcode.isEmpty, !model.busy else { return }
        let value = passcode; passcode = ""; model.authenticateTransferDestination(passcode: value)
    }
}
