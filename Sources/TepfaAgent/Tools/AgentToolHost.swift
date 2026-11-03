import Foundation
import TepfaCore

/// A saved host as the tools see it.
public struct AgentHostInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var group: String?
    public var tags: [String]
    public var permission: AgentPermissionMode
    public var allowlist: [String]
    public var isConnected: Bool

    public init(id: UUID, name: String, hostname: String, port: Int = 22, username: String, group: String? = nil, tags: [String] = [], permission: AgentPermissionMode = .ask, allowlist: [String] = [], isConnected: Bool = false) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.group = group
        self.tags = tags
        self.permission = permission
        self.allowlist = allowlist
        self.isConnected = isConnected
    }

    public var target: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

/// Which way `sftp_transfer` copies.
public enum AgentTransferDirection: String, Codable, Sendable {
    case upload, download
}

/// Shown to the user before a command runs.
public struct AgentApprovalRequest: Sendable, Identifiable {
    public let id: UUID
    public var source: AgentActionSource
    public var host: AgentHostInfo
    public var tool: String
    /// The shell command about to run (editable in the sheet).
    public var command: String
    /// The model's one-line reason.
    public var reason: String
    /// Why the guardrails are asking (destructive pattern, mode).
    public var detail: String
    public var isDestructive: Bool

    public init(id: UUID = UUID(), source: AgentActionSource, host: AgentHostInfo, tool: String, command: String, reason: String, detail: String, isDestructive: Bool) {
        self.id = id
        self.source = source
        self.host = host
        self.tool = tool
        self.command = command
        self.reason = reason
        self.detail = detail
        self.isDestructive = isDestructive
    }
}

public enum AgentApprovalResponse: Sendable, Equatable {
    case approved
    /// The user changed the command; the new text runs instead.
    case edited(String)
    case denied
}

/// What a command produced.
public struct AgentCommandOutput: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int?
    public var signal: String?
    public var duration: Duration

    public init(stdout: Data, stderr: Data, exitStatus: Int?, signal: String? = nil, duration: Duration) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.signal = signal
        self.duration = duration
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// How much of a tool's command the agent log shows.
public enum AgentEchoMode: Sendable {
    /// The command and its output.
    case full
    /// The command and the exit status only (file contents stay out of the log).
    case commandOnly
}

/// What the app provides to the tools: the saved hosts, a way to run commands
/// on them, the approval sheet and the audit log.
@MainActor
public protocol AgentToolHost: AnyObject {
    func hosts() -> [AgentHostInfo]

    /// Asks the user. Implementations resume with `.denied` when the task is cancelled.
    func approve(_ request: AgentApprovalRequest) async -> AgentApprovalResponse

    /// Runs a command over an exec channel on the host, opening a connection
    /// (and the agent's log tab) when needed. `stdin` is written and closed.
    func execute(on host: AgentHostInfo, command: String, stdin: Data, timeout: Duration, echo: AgentEchoMode, source: AgentActionSource) async throws -> AgentCommandOutput

    /// The user's interactive terminal buffer on the host, newest lines last; nil when none is open.
    func terminalBuffer(on host: AgentHostInfo, maxLines: Int) -> String?

    func audit(_ record: AgentAuditRecord)
}
