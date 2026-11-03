import SwiftUI
import TepfaTerminal

/// Asks for a private key's passphrase.
struct PassphrasePromptView: View {
    let identity: IdentityDescriptor
    let attemptFailed: Bool
    let respond: (SecretAnswer?) -> Void

    @State private var passphrase = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Passphrase for \(identity.name)", systemImage: "key.fill")
                .font(.title3.weight(.semibold))
            if attemptFailed {
                Label("The passphrase was not accepted. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if !identity.privateKeyPath.isEmpty {
                Text(identity.privateKeyPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            Toggle("Remember in Keychain", isOn: $remember)
            Text("A remembered passphrase is unlocked with Touch ID or your login password.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { respond(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unlock", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .onAppear { focused = true }
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        respond(SecretAnswer(secret: passphrase, remember: remember))
    }
}
