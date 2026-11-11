import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH

struct GenerateKeySheet: View {
    let onCreated: (Identity) -> Void

    enum Storage: String, CaseIterable, Identifiable {
        case keychain
        case file

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = "My key"
    @State private var username = ""
    @State private var type: SSHKeyPair.GenerationType = .ed25519
    @State private var comment = IdentityOperations.defaultComment
    @State private var storage: Storage = .keychain
    @State private var filePath = NSHomeDirectory() + "/.ssh/id_ed25519_tepfasonic"
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var rememberPassphrase = true
    @State private var isGenerating = false
    @State private var error: String?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (storage == .keychain || !filePath.isEmpty)
            && passphrase == confirmation
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Key") {
                    TextField("Name", text: $name)
                    TextField("Username", text: $username, prompt: Text("Use the host's username"))
                    Picker("Type", selection: $type) {
                        ForEach(SSHKeyPair.GenerationType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("Comment", text: $comment)
                    if type == .rsa3072 || type == .rsa4096 {
                        Text("RSA keys can be exported and pushed to servers, but cannot be used to connect from Tepfasonic yet.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Storage") {
                    Picker("Keep the private key", selection: $storage) {
                        Text("In the Keychain (recommended)").tag(Storage.keychain)
                        Text("In a file").tag(Storage.file)
                    }
                    .pickerStyle(.radioGroup)
                    if storage == .keychain {
                        Text("The key never touches disk. It is unlocked with Touch ID or your login password and can be exported later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Path", text: $filePath)
                            .font(.body.monospaced())
                        SecureField("Passphrase (optional)", text: $passphrase)
                        SecureField("Confirm passphrase", text: $confirmation)
                        if !passphrase.isEmpty {
                            Toggle("Remember the passphrase in the Keychain", isOn: $rememberPassphrase)
                        }
                        Text("A .pub file is written next to the private key so other tools can use it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .themedForm()

            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isGenerating { ProgressView().controlSize(.small) }
                Button("Generate") { Task { await generate() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isGenerating)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
        .onChange(of: type) { _, newType in
            let base = NSHomeDirectory() + "/.ssh/"
            switch newType {
            case .ed25519: filePath = base + "id_ed25519_tepfasonic"
            case .ecdsaP256, .ecdsaP384, .ecdsaP521: filePath = base + "id_ecdsa_tepfasonic"
            case .rsa3072, .rsa4096: filePath = base + "id_rsa_tepfasonic"
            }
        }
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        let type = type
        let comment = comment
        do {
            let pair = try await Task.detached(priority: .userInitiated) {
                try SSHKeyPair.generate(type, comment: comment.isEmpty ? nil : comment)
            }.value
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let identity: Identity
            switch storage {
            case .keychain:
                identity = try IdentityOperations.createKeychainIdentity(name: trimmedName, username: username, pair: pair, in: modelContext)
            case .file:
                let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    error = "A file already exists at \(url.path). Choose another path."
                    return
                }
                identity = try IdentityOperations.createFileIdentity(
                    name: trimmedName, username: username, pair: pair, at: url,
                    passphrase: passphrase.isEmpty ? nil : passphrase,
                    rememberPassphrase: rememberPassphrase, in: modelContext)
            }
            onCreated(identity)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
