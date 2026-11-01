import SwiftUI

struct ProtectedActionView: View {
    @EnvironmentObject var model: AppModel
    let request: VaultActionRequest
    @State private var passcode = ""
    @State private var confirmation = ""
    private var deleting: Bool { request.kind == .delete }
    private typealias D = HarborDesign
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            Label(deleting ? "Delete vault" : "Verify before sharing", systemImage: deleting ? "trash" : "square.and.arrow.up")
                .font(D.heading(23, .semibold))
            Text(deleting
                 ? "Permanently remove “\(request.header.name)” and every encrypted file inside it."
                 : "Share \(request.items.count) selected item\(request.items.count == 1 ? "" : "s") using AirDrop, Messages, or another available Mac service.")
                .font(D.font(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.actionAuthenticated {
                Label("Identity verified · valid for 60 seconds", systemImage: "checkmark.circle.fill").font(D.font(11, .medium)).foregroundStyle(D.green)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Fresh authentication required").font(D.font(12, .medium))
                    if request.header.macUnlock != nil {
                        Button { passcode = ""; model.authenticateProtectedAction(useMac: true) } label: {
                            Label("Verify with Touch ID / Mac password", systemImage: "touchid").frame(maxWidth: .infinity)
                        }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy)
                    }
                    HStack(spacing: 9) {
                        PasswordEntry("This vault’s passcode", text: $passcode).harborField().onSubmit(verifyPasscode)
                        Button("Verify", action: verifyPasscode).buttonStyle(HarborButtonStyle()).disabled(passcode.isEmpty || model.busy)
                    }
                }.padding(16).background(D.inset, in: RoundedRectangle(cornerRadius: 14))
            }
            if deleting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Type this exact phrase to confirm:").font(D.font(12, .medium))
                    Text("DELETE \(request.header.name)").font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    TextField("Deletion confirmation", text: $confirmation).harborField().autocorrectionDisabled()
                }
                Text("This cannot be undone. Deleting this vault does not erase other copies, exports, snapshots, or backups.").font(D.font(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("After verification, the app creates temporary readable copies for the selected service. They’re removed when sharing finishes or is cancelled. The destination app may keep its own copies.")
                    .font(D.font(11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { Text(error).font(D.font(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { passcode = ""; model.cancelProtectedAction() }.buttonStyle(HarborButtonStyle()).keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if deleting {
                    Button { model.confirmDeleteVault(confirmation) } label: { Text("Delete vault").foregroundStyle(.red) }
                        .buttonStyle(HarborButtonStyle()).disabled(model.busy || !model.actionAuthenticated || confirmation != "DELETE \(request.header.name)")
                } else {
                    Button("Choose where to share…") { model.prepareVerifiedShare() }.buttonStyle(HarborButtonStyle(primary: true)).disabled(model.busy || !model.actionAuthenticated)
                }
            }
        }.padding(32).frame(width: 520).background(D.surface).interactiveDismissDisabled(true)
    }
    private func verifyPasscode() {
        guard !passcode.isEmpty, !model.busy else { return }
        let value = passcode; passcode = ""; model.authenticateProtectedAction(passcode: value)
    }
}

