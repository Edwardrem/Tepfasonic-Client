import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Sidebar list of commands run in every session, newest first.
struct HistoryListView: View {
    @Environment(AppState.self) private var appState
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter history", text: $search)
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
            HistoryResultsView(search: search.trimmingCharacters(in: .whitespaces))
        }
        .navigationTitle("History")
        .confirmationDialog("Clear the command history?", isPresented: Bindable(appState).isConfirmingClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { HistoryOperations.clearAll() }
        } message: {
            Text("Every recorded command, on every host, is deleted. Snippets are kept.")
        }
    }
}

private struct HistoryResultsView: View {
    let search: String
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [CommandHistoryEntry]
    @State private var selection: UUID?

    init(search: String) {
        self.search = search
        var descriptor = FetchDescriptor<CommandHistoryEntry>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        if !search.isEmpty {
            descriptor.predicate = #Predicate { entry in
                entry.command.localizedStandardContains(search) || entry.hostName.localizedStandardContains(search)
            }
        }
        descriptor.fetchLimit = 500
        _entries = Query(descriptor)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.uuid)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        selection = entry.uuid
                        runAgain(entry)
                    })
                    .contextMenu {
                        Button("Run Again in Current Tab") { runAgain(entry) }
                            .disabled(workspace.focusedSession?.isConnected != true)
                        if let hostID = entry.hostID {
                            Button("Run Again on \(entry.hostName)") {
                                SnippetRunner.run(entry.command, on: .host(hostID), workspace: workspace, context: modelContext)
                            }
                        }
                        Divider()
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.command, forType: .string)
                        }
                        Button("Save as Snippet…") { appState.snippetEditor = .create(folder: nil, command: entry.command) }
                        Divider()
                        Button("Delete", role: .destructive) { modelContext.delete(entry) }
                    }
            }
        }
        .listStyle(.sidebar)
        .themedList()
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command), let entry = entries.first(where: { $0.uuid == selection }) else { return .ignored }
            runAgain(entry)
            return .handled
        }
        .onDeleteCommand {
            if let entry = entries.first(where: { $0.uuid == selection }) { modelContext.delete(entry) }
        }
        .overlay {
            if entries.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label("No History Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Commands you run appear here with their exit status when the host's shell reports it.")
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    private func runAgain(_ entry: CommandHistoryEntry) {
        SnippetRunner.run(entry.command, on: .currentTab, workspace: workspace, context: modelContext)
    }
}

struct HistoryRow: View {
    let entry: CommandHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusBadge
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.command)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(entry.hostName)
                    Text("·")
                    Text(entry.startedAt, format: .relative(presentation: .named))
                    if let directory = entry.workingDirectory {
                        Text("·")
                        Text(directory).lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = entry.exitStatus {
            if status == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Exit status 0")
            } else {
                Text(String(status))
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                    .help("Exit status \(status)")
            }
        } else if entry.finishedAt == nil, entry.source == .shellIntegration {
            Image(systemName: "circle.dotted").foregroundStyle(.secondary).help("Still running, or the session ended")
        } else {
            Image(systemName: "minus.circle").foregroundStyle(.tertiary).help("Exit status unknown: the host's shell has no integration")
        }
    }
}

@MainActor
enum HistoryOperations {
    static var container: ModelContainer?

    static func clearAll() {
        guard let container else { return }
        let context = container.mainContext
        try? context.delete(model: CommandHistoryEntry.self)
        try? context.save()
    }
}
