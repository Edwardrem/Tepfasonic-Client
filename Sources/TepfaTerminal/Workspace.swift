import AppKit
import Foundation
import Observation
import TepfaCore

/// Open tabs, their pane trees and the sessions inside them.
@MainActor
@Observable
public final class Workspace {
    public struct Tab: Identifiable, Hashable, Sendable {
        public let id: UUID
        public var tree: PaneNode
        public var focusedLeafID: UUID
        public var customTitle: String?
    }

    public enum TabStatus: Sendable {
        case connected, connecting, disconnected, failed
    }

    public private(set) var tabs: [Tab] = []
    public var selectedTabID: UUID?
    public private(set) var sessions: [UUID: TerminalSession] = [:]
    /// Bumped whenever something worth persisting changes.
    public private(set) var changeCount = 0

    private let makeSession: @MainActor (HostDescriptor) -> TerminalSession
    private let makeAgentSession: @MainActor (HostDescriptor) -> TerminalSession
    private var wakeObserver: NSObjectProtocol?

    public init(
        makeSession: @escaping @MainActor (HostDescriptor) -> TerminalSession = { TerminalSession(host: $0) },
        makeAgentSession: (@MainActor (HostDescriptor) -> TerminalSession)? = nil
    ) {
        self.makeSession = makeSession
        self.makeAgentSession = makeAgentSession ?? { TerminalSession(host: $0, mode: .agentLog) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessions.values.forEach { $0.systemDidWake() }
            }
        }
    }

    // MARK: - Lookup

    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    public var selectedTabIndex: Int? {
        tabs.firstIndex { $0.id == selectedTabID }
    }

    public var focusedSession: TerminalSession? {
        guard let tab = selectedTab, let sessionID = tab.tree.sessionID(ofLeaf: tab.focusedLeafID) else { return nil }
        return sessions[sessionID]
    }

    public func session(id: UUID) -> TerminalSession? {
        sessions[id]
    }

    public func sessions(in tab: Tab) -> [TerminalSession] {
        tab.tree.sessionIDs.compactMap { sessions[$0] }
    }

    /// Live sessions for a saved host, for sidebar status.
    public func sessions(forHost hostID: UUID) -> [TerminalSession] {
        sessions.values.filter { $0.host.id == hostID }
    }

    public func tab(containingSession sessionID: UUID) -> Tab? {
        tabs.first { $0.tree.sessionIDs.contains(sessionID) }
    }

    /// Every connected session, in tab order.
    public var connectedSessions: [TerminalSession] {
        tabs.flatMap { sessions(in: $0) }.filter(\.isConnected)
    }

    /// Connected sessions whose host is one of `hostIDs`, in tab order.
    public func connectedSessions(forHosts hostIDs: Set<UUID>) -> [TerminalSession] {
        connectedSessions.filter { hostIDs.contains($0.host.id) }
    }

    /// Types `command` into each session and presses Enter.
    public func run(_ command: String, in targets: [TerminalSession]) {
        for session in targets where session.isConnected {
            session.sendCommand(command)
        }
    }

    /// A connected session for `host`, opening a new tab when there is none.
    /// Returns the session; a new one is still connecting when it is returned.
    @discardableResult
    public func reuseOrOpen(host: HostDescriptor) -> TerminalSession {
        if let existing = connectedSessions.first(where: { $0.host.id == host.id }) {
            if let tab = tab(containingSession: existing.id) {
                selectedTabID = tab.id
                changed()
            }
            return existing
        }
        return openTab(host: host)
    }

    public func status(of tab: Tab) -> TabStatus {
        let states = sessions(in: tab).map(\.state)
        if states.contains(where: { $0 == .connected }) { return .connected }
        if states.contains(where: { if case .connecting = $0 { return true }; if case .reconnecting = $0 { return true }; return false }) { return .connecting }
        if states.contains(where: { if case .failed = $0 { return true }; return false }) { return .failed }
        return .disconnected
    }

    public func title(of tab: Tab) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        if let sessionID = tab.tree.sessionID(ofLeaf: tab.focusedLeafID), let session = sessions[sessionID] {
            return session.title
        }
        return sessions(in: tab).first?.title ?? "Terminal"
    }

    public func colorLabel(of tab: Tab) -> String? {
        if let sessionID = tab.tree.sessionID(ofLeaf: tab.focusedLeafID), let color = sessions[sessionID]?.host.colorLabel {
            return color
        }
        return sessions(in: tab).compactMap { $0.host.colorLabel }.first
    }

    // MARK: - Opening

    /// Opens a new tab for `host` and selects it.
    @discardableResult
    /// The agent's log session for a host, if one is open.
    public func agentSession(forHost hostID: UUID) -> TerminalSession? {
        sessions.values.first { $0.mode == .agentLog && $0.host.id == hostID }
    }

    /// Returns the open agent tab for the host, or opens one. The session is
    /// connected (or reconnected) and selected so the user can watch.
    public func openAgentTab(host: HostDescriptor) -> TerminalSession {
        if let existing = agentSession(forHost: host.id) {
            if let tab = tab(containingSession: existing.id) { select(tabID: tab.id) }
            if !existing.isConnected, !existing.isBusy { Task { await existing.connect() } }
            return existing
        }
        let session = register(makeAgentSession(host))
        let leafID = UUID()
        let tab = Tab(id: UUID(), tree: .leaf(id: leafID, sessionID: session.id), focusedLeafID: leafID, customTitle: nil)
        tabs.append(tab)
        selectedTabID = tab.id
        changed()
        Task { await session.connect() }
        return session
    }

    /// True when the tab's focused pane is an agent log.
    public func isAgentTab(_ tab: Tab) -> Bool {
        guard let sessionID = tab.tree.sessionID(ofLeaf: tab.focusedLeafID) else { return false }
        return sessions[sessionID]?.mode == .agentLog
    }

    public func openTab(host: HostDescriptor, connect: Bool = true) -> TerminalSession {
        let session = register(makeSession(host))
        let leafID = UUID()
        let tab = Tab(id: UUID(), tree: .leaf(id: leafID, sessionID: session.id), focusedLeafID: leafID, customTitle: nil)
        tabs.append(tab)
        selectedTabID = tab.id
        changed()
        if connect { Task { await session.connect() } }
        return session
    }

    /// Splits the focused pane. Without `host`, the new pane connects to the same host as the focused one.
    @discardableResult
    public func split(_ axis: SplitAxis, host: HostDescriptor? = nil, connect: Bool = true) -> TerminalSession? {
        guard let index = selectedTabIndex else {
            if let host { return openTab(host: host, connect: connect) }
            return nil
        }
        let tab = tabs[index]
        guard let descriptor = host ?? focusedSession?.host else { return nil }
        let session = register(makeSession(descriptor))
        let newLeafID = UUID()
        tabs[index].tree = tab.tree.splitting(leaf: tab.focusedLeafID, axis: axis, newLeafID: newLeafID, sessionID: session.id)
        tabs[index].focusedLeafID = newLeafID
        changed()
        if connect { Task { await session.connect() } }
        return session
    }

    private func register(_ session: TerminalSession) -> TerminalSession {
        sessions[session.id] = session
        session.focusHandler = { [weak self, weak session] in
            guard let self, let session else { return }
            self.noteFocus(sessionID: session.id)
        }
        session.titleHandler = { [weak self] in self?.changeCount += 1 }
        return session
    }

    // MARK: - Closing

    public func closeFocusedPane() {
        guard let tab = selectedTab else { return }
        closePane(leafID: tab.focusedLeafID, inTab: tab.id)
    }

    public func closePane(leafID: UUID, inTab tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        if let sessionID = tab.tree.sessionID(ofLeaf: leafID) {
            sessions[sessionID]?.disconnect()
            sessions[sessionID] = nil
        }
        if let remaining = tab.tree.removing(leaf: leafID) {
            tabs[index].tree = remaining
            if !remaining.leafIDs.contains(tab.focusedLeafID) {
                tabs[index].focusedLeafID = remaining.leafIDs.first ?? tab.focusedLeafID
                requestFocus(tabs[index])
            }
        } else {
            removeTab(at: index)
        }
        changed()
    }

    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for session in sessions(in: tabs[index]) {
            session.disconnect()
            sessions[session.id] = nil
        }
        removeTab(at: index)
        changed()
    }

    public func closeOtherTabs(keeping id: UUID) {
        for tab in tabs where tab.id != id {
            closeTab(id: tab.id)
        }
    }

    private func removeTab(at index: Int) {
        let wasSelected = tabs[index].id == selectedTabID
        tabs.remove(at: index)
        if wasSelected {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Disconnects everything, e.g. at quit. Tabs are kept so they can be snapshotted.
    public func disconnectAll() {
        sessions.values.forEach { $0.disconnect() }
    }

    // MARK: - Selection and focus

    public func select(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
        changed()
        if let tab = selectedTab { requestFocus(tab) }
    }

    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabID: tabs[index].id)
    }

    public func selectNextTab() {
        guard let index = selectedTabIndex, !tabs.isEmpty else { return }
        selectTab(at: (index + 1) % tabs.count)
    }

    public func selectPreviousTab() {
        guard let index = selectedTabIndex, !tabs.isEmpty else { return }
        selectTab(at: (index - 1 + tabs.count) % tabs.count)
    }

    public func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination) else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        changed()
    }

    public func focus(leafID: UUID) {
        guard let index = selectedTabIndex, tabs[index].tree.leafIDs.contains(leafID) else { return }
        tabs[index].focusedLeafID = leafID
        requestFocus(tabs[index])
        changed()
    }

    public func focus(direction: PaneDirection) {
        guard let tab = selectedTab, let target = tab.tree.neighbor(of: tab.focusedLeafID, direction: direction) else { return }
        focus(leafID: target)
    }

    public func isFocused(leafID: UUID) -> Bool {
        selectedTab?.focusedLeafID == leafID
    }

    private func noteFocus(sessionID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.tree.sessionIDs.contains(sessionID) }),
              let leafID = tabs[tabIndex].tree.leafID(ofSession: sessionID) else { return }
        if selectedTabID != tabs[tabIndex].id { selectedTabID = tabs[tabIndex].id }
        if tabs[tabIndex].focusedLeafID != leafID { tabs[tabIndex].focusedLeafID = leafID }
    }

    private func requestFocus(_ tab: Tab) {
        guard let sessionID = tab.tree.sessionID(ofLeaf: tab.focusedLeafID) else { return }
        sessions[sessionID]?.requestFocus()
    }

    public func setFraction(_ fraction: Double, splitID: UUID, tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].tree = tabs[index].tree.settingFraction(fraction, forSplit: splitID)
        changed()
    }

    public func rename(tabID: UUID, to title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].customTitle = title?.isEmpty == true ? nil : title
        changed()
    }

    private func changed() {
        changeCount += 1
    }

    // MARK: - Persistence

    public func snapshot() -> WorkspaceSnapshot {
        var sessionHosts: [UUID: UUID] = [:]
        var transient: [UUID: HostDescriptor] = [:]
        for session in sessions.values where session.mode == .shell {
            if session.host.isTransient {
                transient[session.id] = session.host
            } else {
                sessionHosts[session.id] = session.host.id
            }
        }
        // Agent log tabs are not restored: their leaves are dropped, and tabs left empty with them.
        let agentSessionIDs = Set(sessions.values.filter { $0.mode == .agentLog }.map(\.id))
        let savedTabs: [WorkspaceSnapshot.Tab] = tabs.compactMap { tab in
            var tree: PaneNode? = tab.tree
            for leaf in tab.tree.leaves where agentSessionIDs.contains(leaf.sessionID) {
                tree = tree?.removing(leaf: leaf.id)
            }
            guard let tree else { return nil }
            let focused = tree.leafIDs.contains(tab.focusedLeafID) ? tab.focusedLeafID : tree.leafIDs[0]
            return WorkspaceSnapshot.Tab(id: tab.id, tree: tree, focusedLeafID: focused, customTitle: tab.customTitle)
        }
        return WorkspaceSnapshot(
            tabs: savedTabs,
            selectedTabID: selectedTabID,
            sessionHosts: sessionHosts,
            transientHosts: transient)
    }

    /// Rebuilds tabs from a snapshot. `hosts` resolves saved host UUIDs to current descriptors;
    /// `shouldConnect` decides which restored sessions connect immediately.
    public func restore(_ snapshot: WorkspaceSnapshot, hosts: (UUID) -> HostDescriptor?, shouldConnect: (HostDescriptor) -> Bool) {
        for tab in snapshot.tabs {
            var tree: PaneNode? = tab.tree
            for leaf in tab.tree.leaves {
                let descriptor: HostDescriptor?
                if let hostID = snapshot.sessionHosts[leaf.sessionID] {
                    descriptor = hosts(hostID)
                } else {
                    descriptor = snapshot.transientHosts[leaf.sessionID]
                }
                guard let descriptor else {
                    tree = tree?.removing(leaf: leaf.id)
                    continue
                }
                let session = register(makeSession(descriptor))
                tree = tree?.replacingSession(leaf.sessionID, with: session.id)
                if shouldConnect(descriptor) {
                    Task { await session.connect() }
                }
            }
            guard let tree else { continue }
            let focused = tree.leafIDs.contains(tab.focusedLeafID) ? tab.focusedLeafID : tree.leafIDs[0]
            tabs.append(Tab(id: tab.id, tree: tree, focusedLeafID: focused, customTitle: tab.customTitle))
        }
        if let selected = snapshot.selectedTabID, tabs.contains(where: { $0.id == selected }) {
            selectedTabID = selected
        } else {
            selectedTabID = tabs.first?.id
        }
        changed()
    }
}

extension PaneNode {
    func replacingSession(_ old: UUID, with new: UUID) -> PaneNode {
        switch self {
        case .leaf(let id, let sessionID):
            return .leaf(id: id, sessionID: sessionID == old ? new : sessionID)
        case .split(let id, let axis, let first, let second, let fraction):
            return .split(id: id, axis: axis, first: first.replacingSession(old, with: new), second: second.replacingSession(old, with: new), fraction: fraction)
        }
    }
}
