import AppKit
import SwiftUI
import TepfaCore

/// Export, import and the automatic backups.
struct DataSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var backups: [URL] = Backups.list()

    var body: some View {
        Form {
            Section("Export and import") {
                HStack {
                    Button("Export…") { appState.isExporting = true }
                    Button("Import…") { appState.importRequest = .chooseFile }
                    Spacer()
                }
                Text("A .tepfa file carries hosts, groups, identities, snippets and trusted host keys, encrypted with a passphrase by default. Move between Macs by exporting on one and importing on the other; the import shows what is new or changed before anything is written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Backups") {
                if backups.isEmpty {
                    Text("No backups yet. The last \(Backups.keep) exports and pre-import snapshots are kept here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backups, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                Text(sizeDescription(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore…") { appState.importRequest = .file(url) }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Show in Finder")
                        }
                    }
                    Text("Restoring opens the backup as an import, so you can review what changes before it is applied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom)
        .onAppear { backups = Backups.list() }
        .onChange(of: appState.importRequest) { _, _ in backups = Backups.list() }
    }

    private func sizeDescription(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let encrypted = (try? Data(contentsOf: url)).map(TepfaFile.isEncrypted) ?? false
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + (encrypted ? " · encrypted" : " · plain")
    }
}
