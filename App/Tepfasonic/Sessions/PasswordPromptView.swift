import SwiftUI
import TepfaTerminal

struct PasswordPromptView: View {
    let host: HostDescriptor
    let respond: (SecretAnswer?) -> Void

    @State private var password = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Password for \(host.target)", systemImage: "lock.fill")
                .font(.title3.weight(.semibold))
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            if host.isTransient {
                Text("Quick-connect passwords are used for this connection only and are not stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Remember in Keychain", isOn: $remember)
                Text(remember
                     ? "The password is stored in your login Keychain and unlocked with Touch ID or your login password."
                     : "The password is kept in memory for this session only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { respond(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        respond(SecretAnswer(secret: password, remember: remember && !host.isTransient))
    }
}
