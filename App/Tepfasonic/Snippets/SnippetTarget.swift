import AppKit
import Foundation
import SwiftData
import TepfaCore
import TepfaTerminal

/// Where a snippet or history entry runs.
enum SnippetTarget: Hashable {
    case currentTab
    case allTabs
    case group(UUID)
    case host(UUID)

    @MainActor
    func title(in context: ModelContext) -> String {
        switch self {
        case .currentTab: "the current tab"
        case .allTabs: "every open tab"
        case .group(let id):
            "every host in " + ((try? context.fetch(FetchDescriptor<HostGroup>(predicate: #Predicate { $0.uuid == id })))?.first?.name ?? "the group")
        case .host(let id):
            ((try? context.fetch(FetchDescriptor<SSHHost>(predicate: #Predicate { $0.uuid == id })))?.first?.name ?? "the host")
        }
    }
}

/// Resolves a target to sessions and types the command into them.
@MainActor
enum SnippetRunner {
    /// Sessions a target currently resolves to, for previews. Group and host
    /// targets may open new tabs when run, so this can be empty for them.
    static func sessions(for target: SnippetTarget, workspace: Workspace) -> [TerminalSession] {
        switch target {
        case .currentTab: workspace.focusedSession.map { [$0] } ?? []
        case .allTabs: workspace.connectedSessions
        case .group, .host: []
        }
    }

    /// Runs `command` on `target`, opening tabs for hosts that have none. Returns
    /// false when there was nowhere to run it.
    @discardableResult
    static func run(_ command: String, on target: SnippetTarget, workspace: Workspace, context: ModelContext) -> Bool {
        switch target {
        case .currentTab:
            guard let session = workspace.focusedSession, session.isConnected else {
                NSSound.beep()
                return false
            }
            session.sendCommand(command)
            return true
        case .allTabs:
            let sessions = workspace.connectedSessions
            guard !sessions.isEmpty else {
                NSSound.beep()
                return false
            }
            workspace.run(command, in: sessions)
            return true
        case .group(let id):
            let hosts = (try? context.fetch(FetchDescriptor<SSHHost>(predicate: #Predicate { $0.group?.uuid == id }))) ?? []
            guard !hosts.isEmpty else {
                NSSound.beep()
                return false
            }
            for host in hosts.sorted(by: { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }) {
                host.lastConnectedAt = .now
                workspace.reuseOrOpen(host: HostDescriptor(host)).sendCommandWhenReady(command)
            }
            return true
        case .host(let id):
            guard let host = (try? context.fetch(FetchDescriptor<SSHHost>(predicate: #Predicate { $0.uuid == id })))?.first else {
                NSSound.beep()
                return false
            }
            host.lastConnectedAt = .now
            workspace.reuseOrOpen(host: HostDescriptor(host)).sendCommandWhenReady(command)
            return true
        }
    }

    /// Runs a snippet: straight away when it has no variables, otherwise via the run sheet.
    static func run(_ snippet: Snippet, on target: SnippetTarget, workspace: Workspace, context: ModelContext, appState: AppState) {
        if snippet.variables.isEmpty {
            if run(snippet.command, on: target, workspace: workspace, context: context) {
                snippet.noteUsed()
            }
        } else {
            appState.snippetRun = AppState.SnippetRun(snippet: snippet, target: target)
        }
    }
}
