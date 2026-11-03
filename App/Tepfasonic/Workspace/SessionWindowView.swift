import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// "Connect in New Window": a window with its own workspace holding one host.
struct SessionWindowView: View {
    let hostID: UUID?
    @Query private var hosts: [SSHHost]
    @State private var workspace = Workspace()
    @State private var appState = AppState()
    @State private var opened = false

    var body: some View {
        WorkspaceView()
            .environment(workspace)
            .environment(appState)
            .frame(minWidth: 600, minHeight: 400)
            .task {
                guard !opened, let hostID, let host = hosts.first(where: { $0.uuid == hostID }) else { return }
                opened = true
                workspace.openTab(host: HostDescriptor(host))
            }
            .sheet(item: Bindable(appState).hostEditor) { target in
                HostEditorView(target: target)
            }
    }
}
