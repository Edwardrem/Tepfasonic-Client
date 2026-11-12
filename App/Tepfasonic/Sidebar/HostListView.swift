import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal
import UniformTypeIdentifiers

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

    /// Collapsed groups, remembered between launches.
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroupsRaw = ""
    @State private var dropTarget: UUID?
    @State private var groupToDelete: HostGroup?

    var body: some View {
        List(selection: $selection) {
            let ungrouped = HostGrouping.members(of: nil, in: hosts)
            if !ungrouped.isEmpty {
                Section {
                    hostRows(ungrouped, in: nil)
                } header: {
                    groupHeader(nil, name: "Hosts", color: nil, count: ungrouped.count)
                }
            }
            ForEach(groups) { group in
                let members = HostGrouping.members(of: group, in: hosts)
                Section(isExpanded: expansion(of: group)) {
                    hostRows(members, in: group)
                    if members.isEmpty {
                        Text("No hosts yet. Drag hosts here or right-click to add one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .selectionDisabled()
                    }
                } header: {
                    groupHeader(group, name: group.name, color: HostColor.color(group.colorLabel), count: members.count)
                        .contextMenu {
                            Button("New Host in \(group.name)…") { appState.hostEditor = .createInGroup(group) }
                            Button("Edit Group…") { appState.groupEditor = group }
                            Button("Connect to All") {
                                for host in members { connect(host) }
                            }
                            .disabled(members.isEmpty)
                            Divider()
                            Button("Move Up") { HostGrouping.move(group, by: -1, among: groups) }
                                .disabled(groups.first?.uuid == group.uuid)
                            Button("Move Down") { HostGrouping.move(group, by: 1, among: groups) }
                                .disabled(groups.last?.uuid == group.uuid)
                            Divider()
                            Button("Delete Group…", role: .destructive) {
                                if members.isEmpty { delete(group) } else { groupToDelete = group }
                            }
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
        .themedList()
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
        .confirmationDialog(
            "Delete the group “\(groupToDelete?.name ?? "")”?",
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            titleVisibility: .visible,
            presenting: groupToDelete
        ) { group in
            Button("Delete Group", role: .destructive) { delete(group) }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            let count = HostGrouping.members(of: group, in: hosts).count
            Text("Its \(count) \(count == 1 ? "host is" : "hosts are") kept and move back to Hosts.")
        }
    }

    /// The rows of one group: reorderable by drag, and a drop target for hosts
    /// dragged from other groups.
    @ViewBuilder
    private func hostRows(_ members: [SSHHost], in group: HostGroup?) -> some View {
        ForEach(members) { host in
            row(for: host)
        }
        .onMove { source, destination in
            HostGrouping.reorder(members, fromOffsets: source, toOffset: destination)
        }
        .onInsert(of: [HostDrag.type]) { index, providers in
            HostDrag.loadIDs(from: providers) { ids in drop(ids, into: group, at: index) }
        }
    }

    private func groupHeader(_ group: HostGroup?, name: String, color: Color?, count: Int) -> some View {
        let isTarget = dropTarget == (group?.uuid ?? Self.ungroupedDropID)
        return HStack(spacing: 6) {
            if let color {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(color.gradient).frame(width: 12, height: 12)
            }
            Text(name)
                .font(.callout.weight(.semibold))
            if group != nil, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color ?? .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((color ?? .secondary).opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(isTarget ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onDrop(of: [HostDrag.type], isTargeted: Binding(
            get: { isTarget },
            set: { dropTarget = $0 ? (group?.uuid ?? Self.ungroupedDropID) : (isTarget ? nil : dropTarget) })
        ) { providers in
            HostDrag.loadIDs(from: providers) { ids in drop(ids, into: group, at: nil) }
            return true
        }
    }

    private static let ungroupedDropID = UUID()

    private func expansion(of group: HostGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group.uuid.uuidString) },
            set: { expanded in
                var set = collapsedGroups
                if expanded { set.remove(group.uuid.uuidString) } else { set.insert(group.uuid.uuidString) }
                collapsedGroupsRaw = set.sorted().joined(separator: ",")
            })
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func drop(_ ids: [UUID], into group: HostGroup?, at index: Int?) {
        let moving = ids.compactMap { id in hosts.first { $0.uuid == id } }
        guard !moving.isEmpty else { return }
        HostGrouping.move(moving, to: group, at: index, among: hosts)
        if let group, collapsedGroups.contains(group.uuid.uuidString) { expansion(of: group).wrappedValue = true }
    }

    private var selectedHost: SSHHost? {
        hosts.first { $0.uuid == selection }
    }

    private func row(for host: SSHHost) -> some View {
        HostRow(host: host, sessions: workspace.sessions(forHost: host.uuid))
            .tag(host.uuid)
            .itemProvider { HostDrag.provider(for: [host.uuid]) }
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
                    Button("None") { HostGrouping.move([host], to: nil, among: hosts) }
                        .disabled(host.group == nil)
                    ForEach(groups) { group in
                        Button(group.name) { HostGrouping.move([host], to: group, among: hosts) }
                            .disabled(host.group?.uuid == group.uuid)
                    }
                    Divider()
                    Button("New Group…") { appState.newGroup = NewGroupRequest(hostIDs: [host.uuid]) }
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
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        let compact = themes.appearance.compactSidebar
        HStack(spacing: compact ? 8 : 12) {
            IconTile(systemImage: "cable.connector", color: HostColor.color(profile.colorLabel) ?? HostRow.neutralTile, size: compact ? 22 : 34)
                .overlay(alignment: .bottomTrailing) {
                    if !sessions.isEmpty {
                        StatusDot(color: sessions.contains(where: \.isConnected) ? .green : (sessions.contains(where: \.isBusy) ? .orange : .secondary), size: compact ? 6 : 9)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(compact ? .body : .system(size: Design.sidebarTextSize, weight: .medium))
                    .lineLimit(1)
                if !compact {
                    Text("\((profile.devicePath as NSString).lastPathComponent) · \(profile.lineSummary)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 2 : 5)
    }
}

/// A host in the sidebar: a coloured icon tile with the connection state in its
/// corner, the name, and the target underneath (hidden in the compact density).
struct HostRow: View {
    let host: SSHHost
    let sessions: [TerminalSession]
    @Environment(ThemeStore.self) private var themes

    /// Hosts without a colour label get a calm slate-blue tile: colour without
    /// claiming one of the label hues, which mean something the user chose.
    static let neutralTile = Color(red: 0.36, green: 0.47, blue: 0.68)

    var body: some View {
        let compact = themes.appearance.compactSidebar
        let connected = sessions.filter(\.isConnected).count
        HStack(spacing: compact ? 8 : 12) {
            IconTile(systemImage: "server.rack", color: HostColor.color(host.colorLabel ?? host.group?.colorLabel) ?? Self.neutralTile, size: compact ? 22 : 34)
                .overlay(alignment: .bottomTrailing) {
                    if !sessions.isEmpty {
                        StatusDot(color: statusColor, size: compact ? 6 : 9)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(compact ? .body : .system(size: Design.sidebarTextSize, weight: .medium))
                    .lineLimit(1)
                if !compact {
                    Text(host.displayTarget)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if sessions.contains(where: \.isBusy) {
                ProgressView()
                    .controlSize(.mini)
            } else if connected > 1 {
                Text("\(connected)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.18), in: Capsule())
                    .help("\(connected) terminals connected")
            }
        }
        .padding(.vertical, compact ? 2 : 5)
    }

    private var statusColor: Color {
        if sessions.contains(where: \.isConnected) { return .green }
        if sessions.contains(where: \.isBusy) { return .orange }
        return .secondary
    }
}
