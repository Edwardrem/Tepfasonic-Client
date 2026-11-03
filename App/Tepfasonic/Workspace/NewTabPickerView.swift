import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Popover from the tab bar's "+": pick a saved host or quick-connect.
struct NewTabPickerView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]
    @State private var query = ""

    private var filtered: [SSHHost] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return hosts }
        return hosts.filter { host in
            host.name.lowercased().contains(needle) || host.hostname.lowercased().contains(needle)
                || host.username.lowercased().contains(needle) || host.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search hosts or type user@host:port", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(openFirst)
            List {
                ForEach(filtered) { host in
                    Button {
                        open(host)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(HostColor.color(host.colorLabel ?? host.group?.colorLabel) ?? .secondary.opacity(0.4)).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(host.name)
                                Text(host.displayTarget).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty, let quick = HostDescriptor.quickConnect(query) {
                    Button {
                        workspace.openTab(host: quick)
                        dismiss()
                    } label: {
                        Label("Quick connect to \(quick.target)", systemImage: "bolt")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 160)
        }
        .padding(10)
        .frame(width: 320, height: 300)
    }

    private func openFirst() {
        if let host = filtered.first {
            open(host)
        } else if let quick = HostDescriptor.quickConnect(query) {
            workspace.openTab(host: quick)
            dismiss()
        }
    }

    private func open(_ host: SSHHost) {
        host.lastConnectedAt = .now
        workspace.openTab(host: HostDescriptor(host))
        dismiss()
    }
}
