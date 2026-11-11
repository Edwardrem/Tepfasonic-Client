import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH

struct ImportKeySheet: View {
    let onImported: (Identity) -> Void

    enum Destination: String, CaseIterable, Identifiable {
        case keychain
        case reference

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var identities: [Identity]
    @State private var fileURL: URL?
    @State private var pastedText = ""
    @State private var passphrase = ""
    @State private var name = ""
    @State private var username = ""
    @State private var destination: Destination = .keychain
    @State private var rememberPassphrase = true
    @State private var parsed: SSHKeyPair?
    @State private var needsPassphrase = false
    @State private var error: String?

    private var sourceText: String? {
        if let fileURL { return try? String(contentsOf: fileURL, encoding: .utf8) }
        return pastedText.isEmpty ? nil : pastedText
    }

    private var canImport: Bool {
        parsed != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Source") {
                    HStack {
                        Button("Choose File…") {
                            if let url = IdentityOperations.chooseKeyFile() {
                                fileURL = url
                                pastedText = ""
                                destination = .reference
                                if name.isEmpty { name = url.lastPathComponent }
                                parse()
                            }
                        }
                        if let fileURL {
                            Text(fileURL.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("or paste a key below").foregroundStyle(.secondary)
                        }
                    }
                    if fileURL == nil {
                        TextEditor(text: $pastedText)
                            .font(.caption.monospaced())
                            .frame(height: 110)
                            .onChange(of: pastedText) { _, _ in parse() }
                    }
                    if needsPassphrase {
                        SecureField("Passphrase", text: $passphrase)
                            .onSubmit(parse)
                        HStack {
                            Button("Unlock") { parse() }
                            if fileURL != nil, destination == .reference {
                                Toggle("Remember the passphrase in the Keychain", isOn: $rememberPassphrase)
                            }
                        }
                    }
                    if let parsed {
                        LabeledContent("Type", value: parsed.keyType)
                        LabeledContent("Fingerprint") {
                            Text(parsed.fingerprintSHA256).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if !parsed.canAuthenticate {
                            Text("RSA keys can be stored and pushed, but cannot be used to connect from Tepfasonic yet.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Username", text: $username, prompt: Text("Use the host's username"))
                    if fileURL != nil {
                        Picker("Keep the key", selection: $destination) {
                            Text("As a reference to the file").tag(Destination.reference)
                            Text("Copied into the Keychain").tag(Destination.keychain)
                        }
                        .pickerStyle(.radioGroup)
                    } else {
                        Text("Pasted keys are stored in the Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .themedForm()

            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import") { importKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
            .padding()
        }
        .frame(width: 540, height: 560)
    }

    private func parse() {
        guard let text = sourceText else {
            parsed = nil
            return
        }
        do {
            let pair = try SSHKeyPair.parse(text, passphrase: passphrase.isEmpty ? nil : passphrase)
            parsed = pair
            needsPassphrase = false
            error = nil
            if name.isEmpty, let comment = pair.comment, !comment.isEmpty { name = comment }
        } catch SSHKeyError.passphraseRequired {
            parsed = nil
            needsPassphrase = true
            error = nil
        } catch SSHKeyError.wrongPassphrase {
            parsed = nil
            needsPassphrase = true
            error = "The passphrase is incorrect."
        } catch {
            parsed = nil
            needsPassphrase = false
            self.error = error.localizedDescription
        }
    }

    private func importKey() {
        guard let parsed else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            let identity: Identity
            if let fileURL, destination == .reference {
                identity = try IdentityOperations.identityForKeyFile(at: fileURL, existing: identities, in: modelContext)
                identity.name = trimmedName
                identity.username = username
                if needsPassphraseOnDisk, rememberPassphrase, !passphrase.isEmpty {
                    try IdentityOperations.store.remember(passphrase: passphrase, for: .init(identity))
                }
                try modelContext.save()
            } else {
                identity = try IdentityOperations.createKeychainIdentity(name: trimmedName, username: username, pair: parsed, in: modelContext)
            }
            onImported(identity)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// True when the file itself is encrypted (a passphrase was needed to parse it).
    private var needsPassphraseOnDisk: Bool { !passphrase.isEmpty }
}
