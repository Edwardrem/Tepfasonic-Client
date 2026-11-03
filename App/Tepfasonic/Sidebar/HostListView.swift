import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

struct HostListView: View {
    @Binding var selection: UUID?
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(AgentPanelController.self) private var agent
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: [SortDescriptor(\HostGroup.sortOrder), SortDescriptor(\HostGroup.name)]) private var groups: [HostGroup]
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]
    @Query(sort: [SortDescriptor(\SerialProfile.sortOrder), SortDescriptor(\SerialProfile.name)]) private var serialProfiles: [SerialProfile]

    var body: some View {
        List(selection: $selection) {
            let ungrouped = hosts.filter { $0.group == nil }
            if !ungrouped.isEmpty {
                Section("Hosts") {
                    ForEach(ungrouped) { host in
                        row(for: host)
                    }
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(hosts.filter { $0.group?.uuid == group.uuid }) { host in
                        row(for: host)
                    }
                } header: {
                    HStack(spacing: 6) {
                        if let color = HostColor.color(group.colorLabel) {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(group.name)
                    }
                    .contextMenu {
                        Button("Edit Group…") { appState.groupEditor = group }
                        Button("Connect to All") {
                            for host in hosts.filter({ $0.group?.uuid == group.uuid }) { connect(host) }
                        }
                        Divider()
                        Button("Delete Group", role: .destructive) { delete(group) }
                    }
                }
            }
            if !serialProfiles.isEmpty {
                Section("Serial consoles") {
                    ForEach(serialProfiles) { profile in
                        SerialProfileRow(profile: profile, sessions: workspace.sessions(forHost: profile.uuid))
                            .tag(profile.uuid)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { open(profile) })
                            .contextMenu {
                                Button("Open") { open(profile) }
                                Button("Edit…") { appState.serialProfileEditor = .edit(profile) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(profile) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hosts")
        .overlay {
            if hosts.isEmpty, serialProfiles.isEmpty {
                ContentUnavailableView(
                    "No Hosts",
                    systemImage: "server.rack",
                    description: Text("Add your first SSH host with ⌘N."))
            }
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command), let host = selectedHost else { return .ignored }
            connect(host)
            return .handled
        }
    }

    private var selectedHost: SSHHost? {
        hosts.first { $0.uuid == selection }
    }

    private func row(for host: SSHHost) -> some View {
        HostRow(host: host, sessions: workspace.sessions(forHost: host.uuid))
            .tag(host.uuid)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                selection = host.uuid
                connect(host)
            })
            .contextMenu {
                Button("Connect") { connect(host) }
                Button("Ask Claude About This Host") {
                    agent.focus(.host(host.uuid))
                    appState.isShowingAgentPanel = true
                }
                Button("Connect in New Window") {
                    host.lastConnectedAt = .now
                    openWindow(id: "session", value: host.uuid)
                }
                Button("Browse Files (SFTP)") {
                    appState.sftpHostID = host.uuid
                    openWindow(id: "sftp")
                }
                Button("Port Forwarding…") {
                    selection = host.uuid
                    appState.sidebarMode = .ports
                }
                Divider()
                Button("Edit…") { appState.hostEditor = .edit(host) }
                Button("Duplicate") { duplicate(host) }
                Menu("Move to Group") {
                    Button("None") { host.group = nil }
                        .disabled(host.group == nil)
                    ForEach(groups) { group in
                        Button(group.name) { host.group = group }
                            .disabled(host.group?.uuid == group.uuid)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { delete(host) }
            }
    }

    private func connect(_ host: SSHHost) {
        host.lastConnectedAt = .now
        workspace.openTab(host: HostDescriptor(host))
    }

    private func duplicate(_ host: SSHHost) {
        let copy = SSHHost(
            name: host.name + " copy",
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: host.authMethod,
            tags: host.tags,
            notes: host.notes,
            sortOrder: host.sortOrder + 1,
            colorLabel: host.colorLabel,
            autoReconnect: host.autoReconnect,
            group: host.group,
            identity: host.identity)
        copy.jumpHost = host.jumpHost
        copy.inheritsGroupJumpHost = host.inheritsGroupJumpHost
        copy.proxyKindRaw = host.proxyKindRaw
        copy.proxyHost = host.proxyHost
        copy.proxyPort = host.proxyPort
        copy.proxyUsername = host.proxyUsername
        copy.inheritsGroupProxy = host.inheritsGroupProxy
        copy.themeID = host.themeID
        copy.fontName = host.fontName
        copy.fontSize = host.fontSize
        copy.backgroundTint = host.backgroundTint
        copy.watermark = host.watermark
        copy.defaultSnippet = host.defaultSnippet
        copy.shellIntegration = host.shellIntegration
        copy.agentPermission = host.agentPermission
        copy.agentAllowlist = host.agentAllowlist
        modelContext.insert(copy)
        selection = copy.uuid
    }

    private func delete(_ host: SSHHost) {
        for session in workspace.sessions(forHost: host.uuid) {
            if let tab = workspace.tab(containingSession: session.id), let leaf = tab.tree.leafID(ofSession: session.id) {
                workspace.closePane(leafID: leaf, inTab: tab.id)
            }
        }
        if selection == host.uuid { selection = nil }
        modelContext.delete(host)
    }

    private func delete(_ group: HostGroup) {
        // Hosts are kept (relationship is nullify) and move back to "Hosts".
        modelContext.delete(group)
    }

    private func open(_ profile: SerialProfile) {
        profile.lastConnectedAt = .now
        workspace.openTab(host: HostDescriptor(profile))
    }

    private func delete(_ profile: SerialProfile) {
        for session in workspace.sessions(forHost: profile.uuid) {
            if let tab = workspace.tab(containingSession: session.id), let leaf = tab.tree.leafID(ofSession: session.id) {
                workspace.closePane(leafID: leaf, inTab: tab.id)
            }
        }
        modelContext.delete(profile)
    }
}

struct SerialProfileRow: View {
    let profile: SerialProfile
    let sessions: [TerminalSession]

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "cable.connector")
                    .foregroundStyle(HostColor.color(profile.colorLabel) ?? .secondary)
                    .frame(width: 18)
                if !sessions.isEmpty {
                    Circle()
                        .fill(sessions.contains(where: \.isConnected) ? Color.green : (sessions.contains(where: \.isBusy) ? Color.orange : Color.secondary))
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text("\((profile.devicePath as NSString).lastPathComponent) · \(profile.lineSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct HostRow: View {
    let host: SSHHost
    let sessions: [TerminalSession]

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "server.rack")
                    .foregroundStyle(HostColor.color(host.colorLabel ?? host.group?.colorLabel) ?? .secondary)
                    .frame(width: 18)
                if !sessions.isEmpty {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .lineLimit(1)
                Text(host.displayTarget)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if sessions.contains(where: \.isBusy) {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        if sessions.contains(where: \.isConnected) { return .green }
        if sessions.contains(where: \.isBusy) { return .orange }
        return .secondary
    }
}
