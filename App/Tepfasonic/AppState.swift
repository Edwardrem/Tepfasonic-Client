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
        case hosts, snippets, history, ports

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hosts: "Hosts"
            case .snippets: "Snippets"
            case .history: "History"
            case .ports: "Port Forwarding"
            }
        }

        var systemImage: String {
            switch self {
            case .hosts: "server.rack"
            case .snippets: "text.badge.star"
            case .history: "clock.arrow.circlepath"
            case .ports: "arrow.left.arrow.right"
            }
        }
    }

    enum PortForwardEditorTarget: Identifiable {
        case create(hostID: UUID?)
        case edit(PortForwardRule)

        var id: String {
            switch self {
            case .create(let hostID): "create-\(hostID?.uuidString ?? "any")"
            case .edit(let rule): "edit-\(rule.uuid.uuidString)"
            }
        }
    }

    enum SerialProfileEditorTarget: Identifiable {
        case create
        case edit(SerialProfile)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let profile): "edit-\(profile.uuid.uuidString)"
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
    var groupEditor: HostGroup?
    var portForwardEditor: PortForwardEditorTarget?
    var serialProfileEditor: SerialProfileEditorTarget?
    /// The host whose files are shown in the SFTP window (opened from a session or the sidebar).
    var sftpHostID: UUID?
    var isShowingCloudImport = false
    var isShowingThemeEditor = false
    /// A theme fetched from a `tepfasonic://theme?url=` link, waiting for the user to confirm.
    var pendingThemeInstall: PendingThemeInstall?
}
