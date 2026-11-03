import AppKit
import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

struct IdentityDetailView: View {
    @Bindable var identity: Identity
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var newPassword = ""
    @State private var passwordSaved = false
    @State private var isExportingPrivateKey = false
    @State private var isPushing = false
    @State private var error: String?
    @State private var notice: String?

    private var store: KeychainCredentialStore { IdentityOperations.store }
    private var descriptor: IdentityDescriptor { IdentityDescriptor(identity) }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $identity.name)
                TextField("Username", text: $identity.username, prompt: Text("Use the host's username"))
                LabeledContent("Credential", value: identity.credentialKind.displayName)
            }

            switch identity.credentialKind {
            case .password:
                passwordSection
            case .keyFile, .keychainKey:
                keySection
            }

            Section("Used by") {
                if identity.hosts.isEmpty {
                    Text("No hosts use this identity yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(identity.hosts.sorted { $0.name < $1.name }) { host in
                        Label(host.name, systemImage: "server.rack")
                    }
                }
            }

            Section {
                HStack {
                    Button("Delete Identity…", role: .destructive, action: onDelete)
                    Spacer()
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: identity.name) { _, _ in try? modelContext.save() }
        .onChange(of: identity.username) { _, _ in try? modelContext.save() }
        .sheet(isPresented: $isExportingPrivateKey) {
            ExportPrivateKeySheet(identity: identity)
        }
        .sheet(isPresented: $isPushing) {
            PushKeySheet(identity: identity)
        }
    }

    // MARK: Password identities

    private var passwordSection: some View {
        Section("Password") {
            LabeledContent("Status") {
                if store.hasStoredPassword(forIdentity: identity.uuid) {
                    Label("Saved in Keychain", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                } else {
                    Label("No password saved", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            HStack {
                SecureField("New password", text: $newPassword)
                Button("Save") {
                    do {
                        try store.storePassword(newPassword, forIdentity: identity.uuid, name: identity.name)
                        newPassword = ""
                        notice = "Password updated."
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(newPassword.isEmpty)
            }
        }
    }

    // MARK: Key identities

    @ViewBuilder
    private var keySection: some View {
        Section("Key") {
            LabeledContent("Type", value: identity.keyType ?? "Unknown until unlocked")
            if let fingerprint = identity.fingerprint {
                LabeledContent("Fingerprint") {
                    Text(fingerprint).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            if identity.credentialKind == .keyFile {
                LabeledContent("File") {
                    HStack {
                        Text(identity.privateKeyPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: identity.privateKeyPath)])
                        }
                        .controlSize(.small)
                    }
                }
                LabeledContent("Passphrase") {
                    if store.hasStoredPassphrase(for: descriptor) {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Forget") {
                                store.forgetPassphrase(for: descriptor)
                                notice = "Passphrase forgotten; it will be asked for on the next connection."
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Text("Asked for when connecting, if the file is encrypted").foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Storage", value: "Private key in the login Keychain")
            }
            if identity.keyType == "ssh-rsa" {
                Label("RSA keys can be exported and pushed, but SwiftNIO SSH cannot sign with them, so this identity cannot be used to connect.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Public key") {
            if let publicKey = identity.publicKey {
                Text(publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy") {
                        IdentityOperations.copyToPasteboard(publicKey)
                        notice = "Public key copied."
                    }
                    Button("Export…") {
                        IdentityOperations.savePublicKey(publicKey, suggestedName: suggestedFileName)
                    }
                    Button("Push to Server…") { isPushing = true }
                    Spacer()
                    Button("Export Private Key…") { isExportingPrivateKey = true }
                }
            } else {
                Text("The public key is read when the key is first unlocked.").foregroundStyle(.secondary)
                Button("Unlock and Read Now") { Task { await refreshFromKey() } }
            }
        }
    }

    private var suggestedFileName: String {
        if identity.credentialKind == .keyFile, !identity.privateKeyPath.isEmpty {
            return (identity.privateKeyPath as NSString).lastPathComponent
        }
        return identity.name.replacingOccurrences(of: " ", with: "_")
    }

    private func refreshFromKey() async {
        do {
            let pair = try await store.keyPair(for: descriptor)
            IdentityOperations.apply(pair, to: identity)
            try modelContext.save()
            error = nil
        } catch SSHKeyError.passphraseRequired {
            error = "This key file is encrypted; connect to a host once and remember the passphrase, or re-import it."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Asks for an optional passphrase, then writes the key with a save panel.
struct ExportPrivateKeySheet: View {
    let identity: Identity

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var currentPassphrase = ""
    @State private var error: String?
    @State private var isWorking = false

    private var needsCurrentPassphrase: Bool {
        identity.credentialKind == .keyFile && !IdentityOperations.store.hasStoredPassphrase(for: IdentityDescriptor(identity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Private Key").font(.title3.weight(.semibold))
            Text("The key is written in OpenSSH format. Protect it with a passphrase unless another tool needs it unencrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if needsCurrentPassphrase {
                SecureField("Current passphrase (if the file is encrypted)", text: $currentPassphrase)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("New passphrase (optional)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm passphrase", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Export…") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase != confirmation || isWorking)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func export() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let pair = try await IdentityOperations.store.keyPair(
                for: IdentityDescriptor(identity),
                passphrase: currentPassphrase.isEmpty ? nil : currentPassphrase)
            try IdentityOperations.savePrivateKey(pair, passphrase: passphrase.isEmpty ? nil : passphrase, suggestedName: identity.name.replacingOccurrences(of: " ", with: "_"))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
