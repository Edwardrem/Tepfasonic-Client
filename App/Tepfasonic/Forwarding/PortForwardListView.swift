import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Sidebar: every saved forwarding rule grouped by host, with live status and
/// byte counts, and one-click start and stop.
struct PortForwardListView: View {
    @Environment(AppState.self) private var appState
    @Environment(Workspace.self) private var workspace
    @Environment(PortForwardingManager.self) private var forwarding
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\PortForwardRule.sortOrder), SortDescriptor(\PortForwardRule.createdAt)]) private var rules: [PortForwardRule]
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]

    var body: some View {
        List {
            ForEach(hosts.filter { host in rules.contains { $0.host?.uuid == host.uuid } }) { host in
                Section {
                    ForEach(rules.filter { $0.host?.uuid == host.uuid }) { rule in
                        PortForwardRow(rule: rule, forward: forwarding.forward(for: rule.uuid))
                            .contextMenu { menu(for: rule) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(rule) })
                    }
                } header: {
                    HStack(spacing: 6) {
                        if let color = HostColor.color(host.colorLabel ?? host.group?.colorLabel) {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(host.name)
                        Spacer()
                        if workspace.sessions(forHost: host.uuid).contains(where: \.isConnected) {
                            Text("connected").font(.caption2).foregroundStyle(.green)
                        }
                    }
                }
            }
            let orphans = rules.filter { $0.host == nil }
            if !orphans.isEmpty {
                Section("Rules without a host") {
                    ForEach(orphans) { rule in
                        PortForwardRow(rule: rule, forward: nil)
                            .contextMenu {
                                Button("Edit…") { appState.portForwardEditor = .edit(rule) }
                                Button("Delete", role: .destructive) { delete(rule) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .themedList()
        .navigationTitle("Port Forwarding")
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label("No Forwarding Rules", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Add a local, remote or SOCKS5 rule with the + button. Rules start with a click, or on connect when marked auto-start, and keep working across reconnects.")
                }
            }
        }
        .onAppear { sync() }
        .onChange(of: rules.map { "\($0.uuid)\($0.kindRaw)\($0.bindAddress)\($0.bindPort)\($0.targetHost)\($0.targetPort)\($0.autoStart)\($0.host?.uuid.uuidString ?? "")" }) { _, _ in sync() }
    }

    private func sync() {
        forwarding.reconcile(with: rules.map(PortForwardDescriptor.init))
    }

    @ViewBuilder
    private func menu(for rule: PortForwardRule) -> some View {
        if forwarding.isRunning(rule.uuid) {
            Button("Stop") { Task { await forwarding.stop(rule.uuid) } }
        } else {
            Button("Start") { start(rule) }
        }
        Button("Edit…") { appState.portForwardEditor = .edit(rule) }
        Button("Duplicate") { duplicate(rule) }
        Toggle("Start on Connect", isOn: Binding(get: { rule.autoStart }, set: { rule.autoStart = $0; try? modelContext.save() }))
        Divider()
        Button("Delete", role: .destructive) { delete(rule) }
    }

    private func toggle(_ rule: PortForwardRule) {
        if forwarding.isRunning(rule.uuid) {
            Task { await forwarding.stop(rule.uuid) }
        } else {
            start(rule)
        }
    }

    private func start(_ rule: PortForwardRule) {
        guard let host = rule.host else { return }
        host.lastConnectedAt = .now
        forwarding.start(PortForwardDescriptor(rule), host: HostDescriptor(host))
    }

    private func duplicate(_ rule: PortForwardRule) {
        let copy = PortForwardRule(name: rule.name.isEmpty ? "" : rule.name + " copy", kind: rule.kind, bindAddress: rule.bindAddress, bindPort: rule.bindPort + 1, targetHost: rule.targetHost, targetPort: rule.targetPort, autoStart: false, sortOrder: rule.sortOrder + 1, host: rule.host)
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func delete(_ rule: PortForwardRule) {
        Task { await forwarding.stop(rule.uuid) }
        modelContext.delete(rule)
        try? modelContext.save()
    }
}

struct PortForwardRow: View {
    let rule: PortForwardRule
    let forward: ActiveForward?
    @Environment(PortForwardingManager.self) private var forwarding

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(statusText)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rule.displayName).lineLimit(1)
                    if rule.autoStart {
                        Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.secondary).help("Starts on connect")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let forward {
                Button {
                    Task { await forwarding.stop(rule.uuid) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop")
                .opacity(forward.status == .stopped ? 0.4 : 1)
            } else {
                Button {
                    guard let host = rule.host else { return }
                    forwarding.start(PortForwardDescriptor(rule), host: HostDescriptor(host))
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Start")
                .disabled(rule.host == nil)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard let forward else { return rule.kind.displayName + " · " + PortForwardDescription.describe(kind: rule.kind, bindAddress: rule.bindAddress, bindPort: rule.bindPort, targetHost: rule.targetHost, targetPort: rule.targetPort) }
        switch forward.status {
        case .active(let port):
            let stats = forward.stats
            var parts = ["port \(port)", "↑ \(ByteCountFormatter.string(fromByteCount: stats.bytesSent, countStyle: .binary))", "↓ \(ByteCountFormatter.string(fromByteCount: stats.bytesReceived, countStyle: .binary))"]
            if stats.connectionsOpen > 0 { parts.append("\(stats.connectionsOpen) open") }
            return parts.joined(separator: " · ")
        case .waitingForHost:
            return forward.stats.lastError ?? "Waiting for the host to connect…"
        case .starting:
            return "Starting…"
        case .failed(let message):
            return message
        case .stopped:
            return "Stopped"
        }
    }

    private var statusColor: Color {
        guard let forward else { return .secondary.opacity(0.5) }
        switch forward.status {
        case .active: return .green
        case .starting, .waitingForHost: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusText: String {
        guard let forward else { return "Not running" }
        switch forward.status {
        case .active(let port): return "Active on port \(port)"
        case .starting: return "Starting"
        case .waitingForHost: return "Waiting for the host"
        case .failed(let message): return message
        case .stopped: return "Stopped"
        }
    }
}
