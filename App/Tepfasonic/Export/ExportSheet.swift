import AppKit
import SwiftData
import SwiftUI
import TepfaCore
import UniformTypeIdentifiers

extension UTType {
    static let tepfa = UTType(exportedAs: TepfaFile.uniformTypeIdentifier, conformingTo: .json)
}

/// Chooses what goes into a `.tepfa` file and writes it.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var options = ExportBuilder.Options()
    @State private var encrypt = true
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var includeSecrets = false
    @State private var isWorking = false
    @State private var error: String?

    private var passphraseProblem: String? {
        guard encrypt else { return nil }
        if passphrase.count < 8 { return "Use at least 8 characters." }
        if passphrase != confirmation { return "The passphrases do not match." }
        return nil
    }

    private var canExport: Bool {
        !isWorking && passphraseProblem == nil && (options.hosts || options.identities || options.snippets || options.knownHosts || options.themes || options.serialProfiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Include") {
                    Toggle("Hosts and groups", isOn: $options.hosts)
                    Toggle("Identities", isOn: $options.identities)
                    Toggle("Snippets", isOn: $options.snippets)
                    Toggle("Known host keys", isOn: $options.knownHosts)
                    Toggle("Port forwarding rules", isOn: $options.portForwards)
                        .disabled(!options.hosts)
                    Toggle("Themes", isOn: $options.themes)
                    Toggle("Serial profiles", isOn: $options.serialProfiles)
                }
                Section("Protection") {
                    Toggle("Encrypt with a passphrase", isOn: $encrypt)
                    if encrypt {
                        SecureField("Passphrase", text: $passphrase)
                        SecureField("Confirm passphrase", text: $confirmation)
                        if let passphraseProblem, !passphrase.isEmpty {
                            Text(passphraseProblem).font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Include saved passwords, private keys and passphrases", isOn: $includeSecrets)
                            .disabled(!options.identities)
                        Text(includeSecrets
                             ? "Secrets are read from the Keychain (Touch ID) and stored only inside the encrypted file. Anyone with the file and the passphrase can use them."
                             : "Without secrets, each Mac keeps its own passwords and keys; identities are imported by name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("A plain file is readable by anyone who has it. Passwords and private keys are never written to a plain file.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .themedForm()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Export…") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding()
        }
        .frame(width: 480)
        .onChange(of: encrypt) { _, on in if !on { includeSecrets = false } }
    }

    private func export() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            var exportOptions = options
            exportOptions.secrets = encrypt && includeSecrets
            if exportOptions.secrets {
                try await Vault.shared.ensureUnlocked(reason: "export saved passwords and keys")
            }
            var reader: (@MainActor (Identity) async throws -> TepfaDocument.IdentitySecrets?)?
            var proxyReader: (@MainActor (UUID) async throws -> String?)?
            if exportOptions.secrets {
                reader = { identity in try ExportSecrets.read(identity) }
                proxyReader = { ownerID in try ExportSecrets.readProxyPassword(ownerID: ownerID) }
            }
            let document = try await ExportBuilder.document(
                from: modelContext,
                knownHosts: await KnownHostsStore.shared.allEntries(),
                options: exportOptions,
                appVersion: UpdateManager.currentShortVersion,
                secrets: reader,
                proxyPassword: proxyReader)
            let data: Data = try TepfaFile.encode(document, passphrase: encrypt ? passphrase : nil)

            let panel = NSSavePanel()
            panel.title = "Export Tepfasonic data"
            panel.allowedContentTypes = [.tepfa]
            panel.nameFieldStringValue = Self.suggestedFileName()
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: Data.WritingOptions.atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? Backups.store(data, label: "export")
            dismiss()
        } catch VaultError.cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func suggestedFileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Tepfasonic-\(formatter.string(from: date)).\(TepfaFile.fileExtension)"
    }
}
