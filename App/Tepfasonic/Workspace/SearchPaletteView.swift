import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// ⌘K: one box that finds hosts (and, in later steps, snippets, identities and history).
struct SearchPaletteView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]
    @Query(sort: [SortDescriptor(\Snippet.sortOrder), SortDescriptor(\Snippet.name)]) private var snippets: [Snippet]
    @Environment(\.modelContext) private var modelContext
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    enum Result: Identifiable {
        case host(SSHHost)
        case snippet(Snippet)
        case quickConnect(HostDescriptor)

        var id: String {
            switch self {
            case .host(let host): "host-\(host.uuid)"
            case .snippet(let snippet): "snippet-\(snippet.uuid)"
            case .quickConnect(let descriptor): "quick-\(descriptor.target)"
            }
        }
    }

    private var results: [Result] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Result] = hosts.filter { host in
            needle.isEmpty || host.name.lowercased().contains(needle) || host.hostname.lowercased().contains(needle)
                || host.username.lowercased().contains(needle) || host.tags.contains { $0.lowercased().contains(needle) }
                || (host.group?.name.lowercased().contains(needle) ?? false)
        }.map(Result.host)
        if !needle.isEmpty {
            out += snippets.filter { snippet in
                snippet.name.lowercased().contains(needle) || snippet.command.lowercased().contains(needle)
                    || snippet.tags.contains { $0.lowercased().contains(needle) }
            }.map(Result.snippet)
        }
        if !needle.isEmpty, let quick = HostDescriptor.quickConnect(query) {
            out.append(.quickConnect(quick))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search hosts and snippets, or type user@host to connect", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(activateSelected)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        row(result)
                            .listRowBackground(index == selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = index; activateSelected() }
                    }
                    if results.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedIndex) { _, index in proxy.scrollTo(index) }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    @ViewBuilder
    private func row(_ result: Result) -> some View {
        switch result {
        case .host(let host):
            HStack(spacing: 10) {
                Circle().fill(HostColor.color(host.colorLabel ?? host.group?.colorLabel) ?? .secondary.opacity(0.4)).frame(width: 9, height: 9)
                VStack(alignment: .leading) {
                    Text(host.name)
                    Text(host.displayTarget + (host.group.map { " · \($0.name)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !host.tags.isEmpty {
                    Text(host.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
                }
            }
        case .snippet(let snippet):
            HStack(spacing: 10) {
                Image(systemName: "text.badge.star").foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(snippet.name)
                    Text(snippet.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(workspace.focusedSession?.isConnected == true ? "Run in current tab" : "No connected tab")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .quickConnect(let descriptor):
            Label("Quick connect to \(descriptor.target)", systemImage: "bolt")
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    private func activateSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        switch results[selectedIndex] {
        case .host(let host):
            host.lastConnectedAt = .now
            workspace.openTab(host: HostDescriptor(host))
        case .snippet(let snippet):
            dismiss()
            SnippetRunner.run(snippet, on: .currentTab, workspace: workspace, context: modelContext, appState: appState)
            return
        case .quickConnect(let descriptor):
            workspace.openTab(host: descriptor)
        }
        dismiss()
    }
}
