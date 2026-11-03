import AppKit
import SwiftData
import SwiftUI
import TepfaAgent
import TepfaCore
import TepfaTerminal

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(AgentPanelController.self) private var agent
    @Environment(MCPServerController.self) private var mcp
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query private var hosts: [SSHHost]
    @State private var restored = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $appState.sidebarMode) {
                    ForEach(AppState.SidebarMode.allCases) { mode in
                        Image(systemName: mode.systemImage).tag(mode).help(mode.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                switch appState.sidebarMode {
                case .hosts:
                    QuickConnectBar()
                    Divider()
                    HostListView(selection: $appState.selectedHostID)
                case .snippets:
                    SnippetListView()
                case .history:
                    HistoryListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            WorkspaceView()
                .inspector(isPresented: $appState.isShowingAgentPanel) {
                    AgentPanelView()
                        .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
                }
        }
        .sheet(item: Binding(
            get: { appState.pendingApprovals.first },
            set: { if $0 == nil { appState.pendingApprovals.first?.resume(.denied) } })) { prompt in
            AgentApprovalSheet(prompt: prompt)
        }
        .sheet(item: $appState.hostEditor) { target in
            HostEditorView(target: target)
        }
        .sheet(item: $appState.snippetEditor) { target in
            SnippetEditorView(target: target)
        }
        .sheet(item: $appState.snippetRun) { run in
            RunSnippetSheet(run: run)
        }
        .sheet(isPresented: Binding(get: { appState.folderEditor != nil }, set: { if !$0 { appState.folderEditor = nil } })) {
            SnippetFolderSheet(folder: appState.folderEditor ?? nil)
        }
        .sheet(isPresented: $appState.isExporting) {
            ExportSheet()
        }
        .sheet(isPresented: $appState.isExportingSSHConfig) {
            SSHConfigExportSheet()
        }
        .sheet(item: $appState.importFlow) { flow in
            ImportSheet(flow: flow)
        }
        .onChange(of: appState.importRequest) { _, request in
            guard let request else { return }
            Task {
                let flow = await InteropImport.flow(for: request, context: modelContext)
                appState.importFlow = flow
                appState.importRequest = nil
                #if DEBUG
                // `--qa-import-apply` imports everything new or changed without waiting for a click.
                if CommandLine.arguments.contains("--qa-import-apply"), let flow, case .review(let plan) = flow.stage {
                    await flow.apply(plan)
                }
                #endif
            }
        }
        .sheet(isPresented: $appState.isAddingGroup) {
            GroupEditorView()
        }
        .sheet(isPresented: $appState.isShowingSearch) {
            SearchPaletteView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isShowingAgentPanel.toggle()
                } label: {
                    Label("Claude", systemImage: "sparkles")
                }
                .help("Show or hide the Claude panel (⌘⇧A)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isShowingSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search hosts (⌘K)")
            }
            ToolbarItem(placement: .primaryAction) {
                switch appState.sidebarMode {
                case .hosts:
                    Button {
                        appState.hostEditor = .create
                    } label: {
                        Label("New Host", systemImage: "plus")
                    }
                    .help("New Host (⌘N)")
                case .snippets:
                    Menu {
                        Button("New Snippet…") { appState.snippetEditor = .create(folder: nil, command: nil) }
                        Button("New Folder…") { appState.folderEditor = .some(nil) }
                    } label: {
                        Label("New Snippet", systemImage: "plus")
                    }
                    .help("New snippet or folder")
                case .history:
                    Button {
                        appState.isConfirmingClearHistory = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .help("Clear the command history")
                }
            }
        }
        .task {
            restoreWorkspace()
            openWindowsRequestedOnLaunch()
            await mcp.apply()
        }
        .onChange(of: workspace.changeCount) { _, _ in scheduleSave() }
    }

    private func restoreWorkspace() {
        guard !restored else { return }
        restored = true
        guard let snapshot = WorkspaceSnapshot.load() else { return }
        let hostsByID = Dictionary(hosts.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        workspace.restore(
            snapshot,
            hosts: { id in hostsByID[id].map(HostDescriptor.init) },
            shouldConnect: { $0.usesIdentity })
    }

    /// `--window=identities|settings|export|ssh-config-export` opens a window at launch (used by UI checks).
    /// Debug builds also take `--seed-demo`, `--sidebar=hosts|snippets|history`,
    /// `--connect=<host name>` and `--qa-type=<text>` (typed into the new session).
    private func openWindowsRequestedOnLaunch() {
        #if DEBUG
        if CommandLine.arguments.contains("--seed-demo") { DemoData.seedIfEmpty(in: modelContext) }
        #endif
        for argument in CommandLine.arguments where argument.hasPrefix("--window=") {
            switch argument.dropFirst("--window=".count) {
            case "identities": openWindow(id: IdentitiesView.windowID)
            case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            case "export": appState.isExporting = true
            case "ssh-config-export": appState.isExportingSSHConfig = true
            case "agent": appState.isShowingAgentPanel = true
            default: break
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--qa-approval"), let host = hosts.first {
            // Shows the approval sheet with a sample destructive command (UI checks).
            let info = AgentHostInfo(id: host.uuid, name: host.name, hostname: host.hostname, port: host.port, username: host.username, permission: host.agentPermission)
            let request = AgentApprovalRequest(source: .agentPanel, host: info, tool: "run_command", command: "rm -rf /var/cache/nginx/*", reason: "Clear the stale cache before restarting nginx", detail: "Destructive pattern (rm -rf): always asks, whatever the host's permission mode.", isDestructive: true)
            appState.pendingApprovals.append(AgentApprovalPrompt(request: request))
        }
        for argument in CommandLine.arguments where argument.hasPrefix("--import=") {
            appState.importRequest = .file(URL(fileURLWithPath: String(argument.dropFirst("--import=".count))))
        }
        for argument in CommandLine.arguments where argument.hasPrefix("--qa-export=") {
            // Writes a plain export (or an encrypted one with passphrase "qa" when the path ends in .enc.tepfa).
            let path = String(argument.dropFirst("--qa-export=".count))
            Task {
                let document = try await ExportBuilder.document(from: modelContext, knownHosts: await KnownHostsStore.shared.allEntries(), options: .init(), appVersion: "qa")
                let data = try TepfaFile.encode(document, passphrase: path.hasSuffix(".enc.tepfa") ? "qa" : nil)
                try data.write(to: URL(fileURLWithPath: path))
            }
        }
        for argument in CommandLine.arguments where argument.hasPrefix("--sidebar=") {
            if let mode = AppState.SidebarMode(rawValue: String(argument.dropFirst("--sidebar=".count))) {
                appState.sidebarMode = mode
            }
        }
        for argument in CommandLine.arguments where argument.hasPrefix("--connect=") {
            let name = String(argument.dropFirst("--connect=".count))
            guard let host = hosts.first(where: { $0.name == name }) else { continue }
            let session = workspace.openTab(host: HostDescriptor(host))
            if let typed = CommandLine.arguments.first(where: { $0.hasPrefix("--qa-type=") })?.dropFirst("--qa-type=".count) {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    for character in typed {
                        session.send(text: String(character))
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
            }
        }
        #endif
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = workspace.snapshot()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? snapshot.save()
        }
    }
}
