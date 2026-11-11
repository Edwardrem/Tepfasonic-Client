import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Sidebar list of snippets grouped by folder. Double-click runs in the current tab.
struct SnippetListView: View {
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SnippetFolder.sortOrder), SortDescriptor(\SnippetFolder.name)]) private var folders: [SnippetFolder]
    @Query(sort: [SortDescriptor(\Snippet.sortOrder), SortDescriptor(\Snippet.name)]) private var snippets: [Snippet]
    @Query(sort: [SortDescriptor(\HostGroup.sortOrder), SortDescriptor(\HostGroup.name)]) private var groups: [HostGroup]
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]
    @State private var search = ""
    @State private var selection: UUID?
    @State private var pendingDelete: Snippet?

    private var filtered: [Snippet] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return snippets }
        return snippets.filter {
            $0.name.lowercased().contains(needle) || $0.command.lowercased().contains(needle)
                || $0.tags.contains { $0.lowercased().contains(needle) } || $0.notes.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter snippets", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            List(selection: $selection) {
                let ungrouped = filtered.filter { $0.folder == nil }
                if !ungrouped.isEmpty {
                    Section("Snippets") {
                        ForEach(ungrouped) { row(for: $0) }
                    }
                }
                ForEach(folders) { folder in
                    let inFolder = filtered.filter { $0.folder?.uuid == folder.uuid }
                    if !inFolder.isEmpty || search.isEmpty {
                        Section {
                            ForEach(inFolder) { row(for: $0) }
                        } header: {
                            Label(folder.name, systemImage: "folder")
                                .contextMenu {
                                    Button("New Snippet in \(folder.name)…") { appState.snippetEditor = .create(folder: folder, command: nil) }
                                    Button("Rename…") { appState.folderEditor = .some(folder) }
                                    Button("Delete Folder", role: .destructive) { delete(folder) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .themedList()
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command), let snippet = snippets.first(where: { $0.uuid == selection }) else { return .ignored }
                run(snippet, on: .currentTab)
                return .handled
            }
            .onDeleteCommand {
                if let snippet = snippets.first(where: { $0.uuid == selection }) { pendingDelete = snippet }
            }
        }
        .navigationTitle("Snippets")
        .overlay {
            if snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "text.badge.star")
                } description: {
                    Text("Save commands you run often. Use {{name}} for values to fill in each time.")
                } actions: {
                    Button("New Snippet…") { appState.snippetEditor = .create(folder: nil, command: nil) }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let snippet = pendingDelete { delete(snippet) }
                pendingDelete = nil
            }
        }
    }

    private func row(for snippet: Snippet) -> some View {
        SnippetRow(snippet: snippet)
            .tag(snippet.uuid)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                selection = snippet.uuid
                run(snippet, on: .currentTab)
            })
            .contextMenu {
                Button("Run in Current Tab") { run(snippet, on: .currentTab) }
                    .disabled(workspace.focusedSession?.isConnected != true)
                Button("Run in All Tabs") { run(snippet, on: .allTabs) }
                    .disabled(workspace.connectedSessions.isEmpty)
                Menu("Run on Host") {
                    ForEach(hosts) { host in
                        Button(host.name) { run(snippet, on: .host(host.uuid)) }
                    }
                }
                .disabled(hosts.isEmpty)
                Menu("Run on Group") {
                    ForEach(groups) { group in
                        Button(group.name) { run(snippet, on: .group(group.uuid)) }
                    }
                }
                .disabled(groups.isEmpty)
                Divider()
                Button("Copy Command") { copy(snippet.command) }
                Button("Edit…") { appState.snippetEditor = .edit(snippet) }
                Button("Duplicate") { duplicate(snippet) }
                Menu("Move to Folder") {
                    Button("None") { snippet.folder = nil }.disabled(snippet.folder == nil)
                    ForEach(folders) { folder in
                        Button(folder.name) { snippet.folder = folder }.disabled(snippet.folder?.uuid == folder.uuid)
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = snippet }
            }
    }

    private func run(_ snippet: Snippet, on target: SnippetTarget) {
        SnippetRunner.run(snippet, on: target, workspace: workspace, context: modelContext, appState: appState)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func duplicate(_ snippet: Snippet) {
        let copy = Snippet(name: snippet.name + " copy", command: snippet.command, tags: snippet.tags, notes: snippet.notes, sortOrder: snippet.sortOrder + 1, folder: snippet.folder)
        modelContext.insert(copy)
        selection = copy.uuid
    }

    private func delete(_ snippet: Snippet) {
        if selection == snippet.uuid { selection = nil }
        modelContext.delete(snippet)
    }

    private func delete(_ folder: SnippetFolder) {
        // Snippets are kept (nullify) and move back to the top level.
        modelContext.delete(folder)
    }
}

struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(snippet.name).lineLimit(1)
                if !snippet.variables.isEmpty {
                    Image(systemName: "curlybraces")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Asks for " + snippet.variables.map(\.name).joined(separator: ", "))
                }
                Spacer(minLength: 0)
                if !snippet.tags.isEmpty {
                    Text(snippet.tags.joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Text(snippet.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
