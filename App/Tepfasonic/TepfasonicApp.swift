import AppKit
import SwiftData
import SwiftUI
import TepfaAgent
import TepfaCore
import TepfaTerminal

@main
struct TepfasonicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var appState: AppState
    @State private var workspace: Workspace
    @State private var updates = UpdateManager()
    @State private var agent: AgentPanelController
    @State private var mcp: MCPServerController
    @State private var forwarding: PortForwardingManager
    @State private var themes: ThemeStore
    private let container: ModelContainer

    init() {
        do {
            let schema = Schema(TepfaSchema.models)
            let configuration = ModelConfiguration("Tepfasonic", schema: schema, url: AppPaths.databaseURL)
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not open the Tepfasonic database at \(AppPaths.databaseURL.path): \(error)")
        }
        HistoryOperations.container = container
        let recorder = AppHistoryRecorder(context: container.mainContext)
        let appState = AppState()
        let workspace = Workspace(makeSession: { host in
            TerminalSession(host: host, historyRecorder: recorder)
        })
        let toolHost = AppAgentHost(context: container.mainContext, workspace: workspace, appState: appState)
        _appState = State(initialValue: appState)
        _workspace = State(initialValue: workspace)
        _agent = State(initialValue: AgentPanelController(toolHost: toolHost, context: container.mainContext, workspace: workspace))
        _mcp = State(initialValue: MCPServerController(toolHost: toolHost))
        _forwarding = State(initialValue: PortForwardingManager(workspace: workspace))
        _themes = State(initialValue: ThemeStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(workspace)
                .environment(updates)
                .environment(agent)
                .environment(mcp)
                .environment(forwarding)
                .environment(themes)
                .onAppear {
                    appDelegate.workspace = workspace
                    appDelegate.appState = appState
                    appDelegate.forwarding = forwarding
                    appDelegate.themes = themes
                }
                .preferredColorScheme(themes.appearance.colorScheme)
                .tint(themes.appearance.accentColor)
                .sheet(item: Bindable(updates).availableUpdate) { item in
                    UpdateAvailableView(item: item)
                        .environment(updates)
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
            }
            IdentityCommands()
            CommandGroup(replacing: .importExport) {
                Button("Import…") { appState.importRequest = .chooseFile }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Import From") {
                    Button("~/.ssh/config…") { appState.importRequest = .sshConfig }
                    Button("Termius CSV…") { appState.importRequest = .termius }
                    Button("PuTTY Sessions…") { appState.importRequest = .putty }
                    Button("Tabby Config…") { appState.importRequest = .tabby }
                    Divider()
                    Button("Cloud Provider (AWS, DigitalOcean, Azure)…") { appState.isShowingCloudImport = true }
                    Divider()
                    Button("Terminal Theme File…") { appState.importRequest = .themeFile }
                }
                Divider()
                Button("Export…") { appState.isExporting = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export to ~/.ssh/config…") { appState.isExportingSSHConfig = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Host…") { appState.hostEditor = .create }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Group…") { appState.isAddingGroup = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Snippet…") { appState.snippetEditor = .create(folder: nil, command: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Forwarding Rule…") { appState.portForwardEditor = .create(hostID: appState.selectedHostID) }
                Button("New Serial Console…") { appState.serialProfileEditor = .create }
                Divider()
                Button("New Tab…") { appState.isShowingNewTabPicker = true }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Pane") { workspace.closeFocusedPane() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(workspace.selectedTab == nil)
                Button("Close Tab") { if let id = workspace.selectedTabID { workspace.closeTab(id: id) } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(workspace.selectedTab == nil)
            }
            CommandMenu("Session") {
                Button("Search Everything…") { appState.isShowingSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Split Right") { workspace.split(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(workspace.focusedSession == nil)
                Button("Split Down") { workspace.split(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(workspace.focusedSession == nil)
                Divider()
                Button("Focus Pane Left") { workspace.focus(direction: .left) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Focus Pane Right") { workspace.focus(direction: .right) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Focus Pane Above") { workspace.focus(direction: .up) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Focus Pane Below") { workspace.focus(direction: .down) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("Reconnect") { if let session = workspace.focusedSession { Task { await session.reconnect() } } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(workspace.focusedSession == nil)
                Button("Disconnect") { workspace.focusedSession?.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(workspace.focusedSession?.isConnected != true)
                Divider()
                Button("Lock Saved Secrets") { Vault.shared.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Ask Claude About This Host") {
                    if let host = workspace.focusedSession?.host, !host.isTransient { agent.focus(.host(host.id)) }
                    appState.isShowingAgentPanel = true
                }
                .disabled(workspace.focusedSession == nil)
                Divider()
                Button("Find in Terminal…") { NotificationCenter.default.post(name: .tepfaFindInTerminal, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(workspace.focusedSession == nil)
                Button("Browse Files (SFTP)…") {
                    guard let host = workspace.focusedSession?.host, !host.isTransient, !host.isSerial else { return }
                    appState.sftpHostID = host.id
                    openWindow(id: "sftp")
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(workspace.focusedSession?.host.isTransient != false)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Hosts") { appState.sidebarMode = .hosts }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Show Snippets") { appState.sidebarMode = .snippets }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Show History") { appState.sidebarMode = .history }
                    .keyboardShortcut("y", modifiers: .command)
                Button("Show Port Forwarding") { appState.sidebarMode = .ports }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Theme Editor…") { openWindow(id: ThemeEditorView.windowID) }
                Divider()
                Button(appState.isShowingAgentPanel ? "Hide Claude Panel" : "Show Claude Panel") { appState.isShowingAgentPanel.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Previous Tab") { workspace.selectPreviousTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Tab") { workspace.selectNextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") { workspace.selectTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
            }
        }

        WindowGroup("Session", id: "session", for: UUID.self) { $hostID in
            SessionWindowView(hostID: hostID)
                .environment(themes)
                .environment(forwarding)
        }
        .modelContainer(container)
        .defaultSize(width: 900, height: 600)

        Window("Files", id: "sftp") {
            SFTPWindowView()
                .environment(appState)
                .environment(workspace)
                .environment(themes)
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 680)

        Window("Theme Editor", id: ThemeEditorView.windowID) {
            ThemeEditorView()
                .environment(themes)
                .environment(appState)
        }
        .modelContainer(container)
        .defaultSize(width: 900, height: 620)

        Window("Identities & Keys", id: IdentitiesView.windowID) {
            IdentitiesView()
        }
        .modelContainer(container)
        .defaultSize(width: 860, height: 560)

        Settings {
            SettingsView()
                .environment(updates)
                .environment(appState)
                .environment(mcp)
                .environment(themes)
                .environment(forwarding)
        }
        .modelContainer(container)
    }
}

/// Window menu entry for the Identities & Keys window.
struct IdentityCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Identities & Keys") { openWindow(id: IdentitiesView.windowID) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

/// Saves the workspace and disconnects cleanly at quit; locks secrets on sleep.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: Workspace?
    var appState: AppState?
    var forwarding: PortForwardingManager?
    var themes: ThemeStore?

    /// Double-clicked or dropped `.tepfa` files, theme JSON files, and `tepfasonic://theme?url=` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if url.scheme == "tepfasonic" {
                    handleAppLink(url)
                } else if url.pathExtension == TepfaFile.fileExtension {
                    appState?.importRequest = .file(url)
                } else if url.pathExtension.lowercased() == "json" || url.pathExtension.lowercased() == "itermcolors" {
                    appState?.importRequest = .themeFileAt(url)
                } else {
                    appState?.importRequest = .file(url)
                }
            }
            NSApp.activate()
        }
    }

    @MainActor
    private func handleAppLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch components.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "theme":
            guard let source = components.queryItems?.first(where: { $0.name == "url" })?.value, let themeURL = URL(string: source) else { return }
            appState?.pendingThemeInstall = PendingThemeInstall(sourceURL: themeURL)
        default:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Vault.shared.systemDidSleep() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Vault.shared.systemDidSleep() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MCPBridgeConfig.remove()
            guard let workspace else { return }
            try? workspace.snapshot().save()
            workspace.disconnectAll()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { themes?.systemAppearanceChanged() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
