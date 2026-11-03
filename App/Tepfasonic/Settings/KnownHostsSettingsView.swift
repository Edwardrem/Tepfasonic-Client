import SwiftUI
import TepfaCore

struct KnownHostsSettingsView: View {
    @State private var entries: [KnownHostEntry] = []
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(entries, selection: $selection) {
                TableColumn("Host") { entry in
                    Text(entry.port == 22 ? entry.host : "\(entry.host):\(String(entry.port))")
                }
                TableColumn("Key type") { entry in Text(entry.keyType) }
                    .width(min: 90, ideal: 130)
                TableColumn("Fingerprint") { entry in
                    Text(entry.fingerprintSHA256).font(.caption.monospaced()).textSelection(.enabled)
                }
                TableColumn("Added") { entry in
                    Text(entry.addedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 110, ideal: 150)
            }
            .frame(minHeight: 240)
            HStack {
                Button("Remove") { Task { await removeSelected() } }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("Hosts you have trusted. Removing one makes the next connection ask again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await reload() }
    }

    private func reload() async {
        entries = await KnownHostsStore.shared.allEntries().sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    private func removeSelected() async {
        for entry in entries where selection.contains(entry.id) {
            try? await KnownHostsStore.shared.forget(host: entry.host, port: entry.port, keyType: entry.keyType)
        }
        selection = []
        await reload()
    }
}
