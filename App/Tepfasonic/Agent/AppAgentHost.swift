import AppKit
import Foundation
import SwiftData
import TepfaAgent
import TepfaCore
import TepfaTerminal

/// An approval the user has not answered yet. Shown as a sheet by `ContentView`.
@MainActor
final class AgentApprovalPrompt: Identifiable {
    let id: UUID
    let request: AgentApprovalRequest
    private var continuation: CheckedContinuation<AgentApprovalResponse, Never>?
    private var onResume: ((AgentApprovalPrompt) -> Void)?

    init(request: AgentApprovalRequest) {
        id = request.id
        self.request = request
    }

    fileprivate func arm(_ continuation: CheckedContinuation<AgentApprovalResponse, Never>, onResume: @escaping (AgentApprovalPrompt) -> Void) {
        self.continuation = continuation
        self.onResume = onResume
    }

    /// Answers the request. Later calls do nothing, so cancellation and the
    /// user's click can race safely.
    func resume(_ response: AgentApprovalResponse) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: response)
        onResume?(self)
        onResume = nil
    }
}

/// Connects the agent tools to the app: saved hosts from SwiftData, commands
/// through the workspace's agent log tabs, approvals through a sheet, and the
/// audit log in the database.
@MainActor
final class AppAgentHost: AgentToolHost {
    private let context: ModelContext
    private let workspace: Workspace
    private let appState: AppState

    init(context: ModelContext, workspace: Workspace, appState: AppState) {
        self.context = context
        self.workspace = workspace
        self.appState = appState
    }

    private func savedHosts() -> [SSHHost] {
        (try? context.fetch(FetchDescriptor<SSHHost>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    private func savedHost(id: UUID) -> SSHHost? {
        var descriptor = FetchDescriptor<SSHHost>(predicate: #Predicate { $0.uuid == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func shellSessions(for hostID: UUID) -> [TerminalSession] {
        workspace.sessions.values.filter { $0.mode == .shell && $0.host.id == hostID }
    }

    func info(_ host: SSHHost) -> AgentHostInfo {
        AgentHostInfo(
            id: host.uuid,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            group: host.group?.name,
            tags: host.tags,
            permission: host.agentPermission,
            allowlist: host.agentAllowlist,
            isConnected: shellSessions(for: host.uuid).contains { $0.isConnected })
    }

    func hosts() -> [AgentHostInfo] {
        savedHosts().map(info)
    }

    func approve(_ request: AgentApprovalRequest) async -> AgentApprovalResponse {
        let prompt = AgentApprovalPrompt(request: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prompt.arm(continuation) { [appState] finished in
                    appState.pendingApprovals.removeAll { $0.id == finished.id }
                }
                appState.pendingApprovals.append(prompt)
                if request.source == .mcp {
                    // The request came from another app: bring the sheet forward.
                    NSApp.activate()
                }
            }
        } onCancel: {
            Task { @MainActor in prompt.resume(.denied) }
        }
    }

    func execute(on host: AgentHostInfo, command: String, stdin: Data, timeout: Duration, echo: AgentEchoMode, source: AgentActionSource) async throws -> AgentCommandOutput {
        guard let saved = savedHost(id: host.id) else { throw AgentToolRunner.Failure.unknownHost(host.name) }
        let session = workspace.openAgentTab(host: HostDescriptor(saved))
        let started = ContinuousClock.now
        let result = try await session.runCommand(
            command,
            stdin: Array(stdin),
            outputLimit: 1 << 20,
            timeout: timeout,
            echo: true,
            echoOutput: echo == .full)
        saved.lastConnectedAt = .now
        return AgentCommandOutput(
            stdout: Data(result.stdout),
            stderr: Data(result.stderr),
            exitStatus: result.exitStatus,
            signal: result.signal,
            duration: ContinuousClock.now - started)
    }

    func terminalBuffer(on host: AgentHostInfo, maxLines: Int) -> String? {
        let sessions = shellSessions(for: host.id)
        guard !sessions.isEmpty else { return nil }
        let focused = workspace.focusedSession?.id
        let preferred = sessions.first { $0.id == focused } ?? sessions.first { $0.isConnected } ?? sessions[0]
        return preferred.bufferText(maximumRows: maxLines)
    }

    func audit(_ record: AgentAuditRecord) {
        context.insert(AgentAuditEntry(record))
        try? context.save()
    }
}

extension AgentAuditEntry {
    convenience init(_ record: AgentAuditRecord) {
        self.init(
            uuid: record.id,
            timestamp: record.timestamp,
            source: record.source,
            hostID: record.hostID,
            hostName: record.hostName,
            hostTarget: record.hostTarget,
            tool: record.tool,
            command: record.command,
            proposedCommand: record.proposedCommand,
            reason: record.reason,
            decision: record.decision,
            decisionDetail: record.decisionDetail,
            exitStatus: record.exitStatus,
            durationMilliseconds: record.durationMilliseconds,
            outputExcerpt: record.outputExcerpt,
            conversationID: record.conversationID)
    }
}
