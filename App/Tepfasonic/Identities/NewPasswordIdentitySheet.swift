import SwiftData
import SwiftUI
import TepfaCore

struct NewPasswordIdentitySheet: View {
    let onCreated: (Identity) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && password == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Password Identity").font(.title3.weight(.semibold))
            Text("Reuse one username and password across several hosts. The password lives in your login Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("e.g. Lab admin"))
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $username, prompt: Text("Use the host's username"))
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm password", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        do {
            let identity = try IdentityOperations.createPasswordIdentity(
                name: name.trimmingCharacters(in: .whitespaces), username: username, password: password, in: modelContext)
            onCreated(identity)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
