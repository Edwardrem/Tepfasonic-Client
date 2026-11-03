import AppKit
import SwiftData
import SwiftUI
import TepfaCore

/// Writes saved hosts into a managed block of `~/.ssh/config` so `ssh name` works.
struct SSHConfigExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]
    @State private var error: String?
    @State private var written = false

    private var exportable: (hosts: [SSHConfigFile.ExportableHost], keychainKeys: Int) {
        var out: [SSHConfigFile.ExportableHost] = []
        var taken: Set<String> = []
        var keychainKeys = 0
        for host in hosts {
            let alias = SSHConfigFile.alias(for: host.name, taken: taken)
            taken.insert(alias)
            var identityFile: String?
            if let identity = host.identity, host.authMethod == .privateKey {
                switch identity.credentialKind {
                case .keyFile: identityFile = identity.privateKeyPath
                case .keychainKey: keychainKeys += 1
                case .password: break
                }
            }
            out.append(SSHConfigFile.ExportableHost(alias: alias, hostname: host.hostname, port: host.port, user: host.identity?.username.isEmpty == false ? host.identity!.username : host.username, identityFile: identityFile))
        }
        return (out, keychainKeys)
    }

    private var block: String { SSHConfigFile.managedBlock(for: exportable.hosts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export to ~/.ssh/config").font(.title3.weight(.semibold))
            Text("Adds or replaces one managed block; everything else in the file is left as it is. The previous file is kept as config.tepfa-backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if exportable.keychainKeys > 0 {
                Label("\(exportable.keychainKeys) host(s) use keys kept only in the Keychain; ssh cannot read those, so no IdentityFile is written for them.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(block)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(height: 240)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if written { Label("Written to ~/.ssh/config.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block, forType: .string)
                }
                Spacer()
                Button(written ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !written {
                    Button("Write to ~/.ssh/config") { write() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(hosts.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func write() {
        do {
            let url = SSHConfigFile.defaultURL
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !existing.isEmpty {
                try existing.write(to: url.deletingLastPathComponent().appending(path: "config.tepfa-backup"), atomically: true, encoding: .utf8)
            }
            let updated = SSHConfigFile.replacingManagedBlock(in: existing, with: block)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            written = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
