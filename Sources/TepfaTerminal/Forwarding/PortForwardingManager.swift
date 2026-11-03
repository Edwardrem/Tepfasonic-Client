import Foundation
import Observation
import Synchronization
import TepfaCore
import TepfaSSH

/// A rule that is running (or trying to): its listener or server-side
/// binding, live status and byte counts.
@MainActor
@Observable
public final class ActiveForward: Identifiable {
    public enum Status: Equatable, Sendable {
        case starting
        /// Listening (local, dynamic) or bound on the server (remote) on `port`.
        case active(port: Int)
        /// The listener is up but the host is not connected, so connections are refused for now.
        case waitingForHost
        case failed(String)
        case stopped

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    public let rule: PortForwardDescriptor
    nonisolated public var id: UUID { rule.id }
    public private(set) var status: Status = .starting
    public private(set) var stats = ForwardCounters.Snapshot()
    public private(set) var startedAt = Date.now

    /// The host's current connection, read by the listeners from event loops.
    let connectionBox = ConnectionSlot()
    var local: LocalForwardListener?
    var dynamic: DynamicForwardListener?
    var remote: RemoteForwardBinding?
    /// Identity of the connection the remote binding was last started on.
    var remoteConnectionID: ObjectIdentifier?

    init(rule: PortForwardDescriptor) {
        self.rule = rule
    }

    fileprivate func set(_ status: Status) {
        if self.status != status { self.status = status }
    }

    fileprivate func refreshStats() {
        let snapshot = (local?.counters ?? dynamic?.counters ?? remote?.counters)?.snapshot ?? ForwardCounters.Snapshot()
        if snapshot != stats { stats = snapshot }
    }

    public var counters: ForwardCounters? { local?.counters ?? dynamic?.counters ?? remote?.counters }
}

/// Runs port-forwarding rules against the workspace's sessions. Local and
/// dynamic rules listen on the Mac and use whatever connection the host's
/// session has at the moment, so they survive reconnects; remote rules are
/// re-requested on every new connection. Rules marked auto-start begin as
/// soon as their host connects.
@MainActor
@Observable
public final class PortForwardingManager {
    public private(set) var active: [UUID: ActiveForward] = [:]
    /// Every saved rule, kept current by the app.
    public var rules: [PortForwardDescriptor] = []

    private let workspace: Workspace
    private var tick: Task<Void, Never>?
    /// Rules whose auto-start failed; retried after the host reconnects.
    private var autoStartFailed: Set<UUID> = []

    public init(workspace: Workspace) {
        self.workspace = workspace
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.update()
            }
        }
    }

    public var activeForwards: [ActiveForward] {
        active.values.sorted { $0.startedAt < $1.startedAt }
    }

    public func forward(for ruleID: UUID) -> ActiveForward? {
        active[ruleID]
    }

    public func isRunning(_ ruleID: UUID) -> Bool {
        active[ruleID] != nil
    }

    /// Starts a rule. `host` lets the manager open a session when the host has none.
    public func start(_ rule: PortForwardDescriptor, host: HostDescriptor?) {
        if let existing = active[rule.id] {
            if case .failed = existing.status {
                Task { await stop(rule.id); start(rule, host: host) }
            }
            return
        }
        let forward = ActiveForward(rule: rule)
        active[rule.id] = forward
        if session(for: rule.hostID) == nil, let host {
            workspace.openTab(host: host)
        }
        Task { await launch(forward) }
    }

    public func stop(_ ruleID: UUID) async {
        guard let forward = active.removeValue(forKey: ruleID) else { return }
        forward.set(.stopped)
        await forward.local?.stop()
        await forward.dynamic?.stop()
        await forward.remote?.stop()
        forward.local = nil
        forward.dynamic = nil
        forward.remote = nil
    }

    public func stopAll() async {
        for id in Array(active.keys) { await stop(id) }
    }

    /// Stops forwards whose rule was deleted or changed.
    public func reconcile(with current: [PortForwardDescriptor]) {
        rules = current
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, forward) in active where byID[id] != forward.rule {
            Task { await stop(id) }
        }
    }

    // MARK: Internals

    private func session(for hostID: UUID?) -> TerminalSession? {
        guard let hostID else { return nil }
        let sessions = workspace.sessions.values.filter { $0.host.id == hostID && !$0.host.isSerial }
        return sessions.first { $0.isConnected && $0.mode == .shell }
            ?? sessions.first { $0.isConnected }
            ?? sessions.first { $0.isBusy }
            ?? sessions.first
    }

    private func launch(_ forward: ActiveForward) async {
        let rule = forward.rule
        let box = forward.connectionBox
        let provider: SSHConnectionProvider = { box.value }
        box.set(session(for: rule.hostID)?.activeConnection)
        do {
            switch rule.kind {
            case .local:
                let listener = LocalForwardListener(bindAddress: rule.effectiveBindAddress, port: rule.bindPort, targetHost: rule.targetHost, targetPort: rule.targetPort, provider: provider)
                forward.local = listener
                let port = try await listener.start()
                guard active[rule.id] === forward else { await listener.stop(); return }
                forward.set(box.value == nil ? .waitingForHost : .active(port: port))
            case .dynamic:
                let listener = DynamicForwardListener(bindAddress: rule.effectiveBindAddress, port: rule.bindPort, provider: provider)
                forward.dynamic = listener
                let port = try await listener.start()
                guard active[rule.id] === forward else { await listener.stop(); return }
                forward.set(box.value == nil ? .waitingForHost : .active(port: port))
            case .remote:
                let binding = RemoteForwardBinding(bindAddress: rule.effectiveBindAddress, port: rule.bindPort, targetHost: rule.targetHost, targetPort: rule.targetPort)
                forward.remote = binding
                if let connection = box.value {
                    try await bindRemote(forward, on: connection)
                } else {
                    forward.set(.waitingForHost)
                }
            }
        } catch {
            forward.set(.failed(error.localizedDescription))
        }
    }

    private func bindRemote(_ forward: ActiveForward, on connection: SSHConnection) async throws {
        guard let binding = forward.remote else { return }
        forward.set(.starting)
        forward.remoteConnectionID = ObjectIdentifier(connection)
        let port = try await binding.start(on: connection)
        guard active[forward.id] === forward else { await binding.stop(); return }
        forward.set(.active(port: port))
    }

    /// Once a second: follow the hosts' connections, refresh counters and auto-start rules.
    private func update() {
        for forward in active.values {
            let session = session(for: forward.rule.hostID)
            let connection = session?.activeConnection
            let previous = forward.connectionBox.replace(with: connection)
            let changed = previous !== connection
            switch forward.rule.kind {
            case .local, .dynamic:
                let listening = forward.local?.isListening ?? forward.dynamic?.isListening ?? false
                if listening {
                    if let port = forward.local?.boundPort ?? forward.dynamic?.boundPort {
                        forward.set(connection == nil ? .waitingForHost : .active(port: port))
                    }
                }
            case .remote:
                if changed, let connection {
                    Task { [weak self] in
                        do {
                            try await self?.bindRemote(forward, on: connection)
                        } catch {
                            forward.set(.failed(error.localizedDescription))
                        }
                    }
                } else if connection == nil, forward.status.isActive || forward.status == .starting {
                    forward.set(.waitingForHost)
                }
            }
            forward.refreshStats()
        }

        // Auto-start rules for hosts that are connected.
        let connectedHosts = Set(workspace.sessions.values.filter { $0.isConnected && !$0.host.isTransient && !$0.host.isSerial }.map(\.host.id))
        for rule in rules where rule.autoStart && active[rule.id] == nil && !autoStartFailed.contains(rule.id) {
            guard let hostID = rule.hostID, connectedHosts.contains(hostID) else { continue }
            start(rule, host: nil)
        }
        for (id, forward) in active where forward.rule.autoStart {
            if case .failed = forward.status, !autoStartFailed.contains(id) {
                autoStartFailed.insert(id)
                Task { await stop(id) }
            }
        }
        // A failed auto-start is retried after the host reconnects: forget it once the host is gone.
        autoStartFailed = autoStartFailed.filter { id in
            guard let rule = rules.first(where: { $0.id == id }), let hostID = rule.hostID else { return false }
            return connectedHosts.contains(hostID)
        }
    }
}

/// A reference-typed slot for the connection listeners read from their event loops.
final class ConnectionSlot: Sendable {
    private let storage = Mutex<SSHConnection?>(nil)

    var value: SSHConnection? { storage.withLock { $0 } }

    func set(_ connection: SSHConnection?) {
        storage.withLock { $0 = connection }
    }

    /// Stores `connection` and returns what was there before.
    func replace(with connection: SSHConnection?) -> SSHConnection? {
        storage.withLock { current in
            let old = current
            current = connection
            return old
        }
    }
}
