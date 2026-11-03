import Foundation
import Observation
import TepfaCore
import TepfaTerminal

/// Window-level UI state: selection and which sheet is open.
@MainActor
@Observable
final class AppState {
    enum HostEditorTarget: Identifiable {
        case create
        /// Prefilled from a quick-connect session the user wants to keep.
        case createFrom(HostDescriptor)
        case edit(SSHHost)

        var id: String {
            switch self {
            case .create: "create"
            case .createFrom(let descriptor): "create-\(descriptor.id.uuidString)"
            case .edit(let host): "edit-\(host.uuid.uuidString)"
            }
        }
    }

    enum SidebarMode: String, CaseIterable, Identifiable {
        case hosts, snippets, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hosts: "Hosts"
            case .snippets: "Snippets"
            case .history: "History"
            }
        }

        var systemImage: String {
            switch self {
            case .hosts: "server.rack"
            case .snippets: "text.badge.star"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    enum SnippetEditorTarget: Identifiable {
        case create(folder: SnippetFolder?, command: String?)
        case edit(Snippet)

        var id: String {
            switch self {
            case .create(let folder, _): "create-\(folder?.uuid.uuidString ?? "root")"
            case .edit(let snippet): "edit-\(snippet.uuid.uuidString)"
            }
        }
    }

    /// A snippet about to run: the sheet asks for variable values and shows the targets.
    struct SnippetRun: Identifiable {
        let id = UUID()
        let snippet: Snippet
        let target: SnippetTarget
    }

    var selectedHostID: UUID?
    var hostEditor: HostEditorTarget?
    var isAddingGroup = false
    var isShowingSearch = false
    var isShowingNewTabPicker = false
    var sidebarMode: SidebarMode = .hosts
    var snippetEditor: SnippetEditorTarget?
    var snippetRun: SnippetRun?
    var folderEditor: SnippetFolder?? // nil: closed; .some(nil): new folder; .some(folder): rename
    var isConfirmingClearHistory = false
    var isExporting = false
    var isExportingSSHConfig = false
    /// Set by the File menu, the Dock/Finder, or Settings; `ContentView` starts the flow.
    var importRequest: ImportRequest?
    var importFlow: ImportFlow?
    /// The Claude panel beside the workspace (⌘⇧A).
    var isShowingAgentPanel = false
    /// Commands waiting for the user; the first one is on screen.
    var pendingApprovals: [AgentApprovalPrompt] = []
}
