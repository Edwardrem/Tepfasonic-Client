import Foundation
import SwiftData

/// Who asked for an agent action.
public enum AgentActionSource: String, Codable, Sendable, CaseIterable {
    case agentPanel = "agent"
    case mcp
}

/// What the guardrails decided about an agent action.
public enum AgentAuditDecision: String, Codable, Sendable, CaseIterable {
    /// Allowed by the host's mode without asking (read-only list or allowlist match).
    case autoAllowed = "auto-allowed"
    case approved
    /// The user changed the command in the approval sheet before running it.
    case edited
    case denied
    /// Refused by read-only mode or another rule; the user was not asked.
    case blocked
    case cancelled

    public var displayName: String {
        switch self {
        case .autoAllowed: "Auto-allowed"
        case .approved: "Approved"
        case .edited: "Edited"
        case .denied: "Denied"
        case .blocked: "Blocked"
        case .cancelled: "Cancelled"
        }
    }

    public var ran: Bool {
        switch self {
        case .autoAllowed, .approved, .edited: true
        case .denied, .blocked, .cancelled: false
        }
    }
}

/// One line of the agent audit log: every command or file change the agent
/// asked for, where, when, what was decided and how it ended.
@Model
public final class AgentAuditEntry {
    @Attribute(.unique) public var uuid: UUID
    public var timestamp: Date
    public var sourceRaw: String
    public var hostID: UUID?
    public var hostName: String
    public var hostTarget: String
    /// Tool name: run_command, write_file, sftp_transfer, …
    public var tool: String
    /// The command (or action) as it ran, after any edit.
    public var command: String
    /// The command as the model proposed it, when the user edited it.
    public var proposedCommand: String?
    public var reason: String
    public var decisionRaw: String
    /// Why the guardrails decided what they did (e.g. the destructive pattern matched).
    public var decisionDetail: String
    public var exitStatus: Int?
    public var durationMilliseconds: Int?
    public var outputExcerpt: String
    public var conversationID: UUID?

    public init(
        uuid: UUID = UUID(),
        timestamp: Date = .now,
        source: AgentActionSource,
        hostID: UUID?,
        hostName: String,
        hostTarget: String,
        tool: String,
        command: String,
        proposedCommand: String? = nil,
        reason: String,
        decision: AgentAuditDecision,
        decisionDetail: String = "",
        exitStatus: Int? = nil,
        durationMilliseconds: Int? = nil,
        outputExcerpt: String = "",
        conversationID: UUID? = nil
    ) {
        self.uuid = uuid
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.hostID = hostID
        self.hostName = hostName
        self.hostTarget = hostTarget
        self.tool = tool
        self.command = command
        self.proposedCommand = proposedCommand
        self.reason = reason
        self.decisionRaw = decision.rawValue
        self.decisionDetail = decisionDetail
        self.exitStatus = exitStatus
        self.durationMilliseconds = durationMilliseconds
        self.outputExcerpt = outputExcerpt
        self.conversationID = conversationID
    }

    public var source: AgentActionSource {
        get { AgentActionSource(rawValue: sourceRaw) ?? .agentPanel }
        set { sourceRaw = newValue.rawValue }
    }

    public var decision: AgentAuditDecision {
        get { AgentAuditDecision(rawValue: decisionRaw) ?? .blocked }
        set { decisionRaw = newValue.rawValue }
    }
}

/// The exportable form of an audit entry.
public struct AgentAuditRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var source: AgentActionSource
    public var hostID: UUID?
    public var hostName: String
    public var hostTarget: String
    public var tool: String
    public var command: String
    public var proposedCommand: String?
    public var reason: String
    public var decision: AgentAuditDecision
    public var decisionDetail: String
    public var exitStatus: Int?
    public var durationMilliseconds: Int?
    public var outputExcerpt: String
    public var conversationID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        source: AgentActionSource,
        hostID: UUID?,
        hostName: String,
        hostTarget: String,
        tool: String,
        command: String,
        proposedCommand: String? = nil,
        reason: String,
        decision: AgentAuditDecision,
        decisionDetail: String = "",
        exitStatus: Int? = nil,
        durationMilliseconds: Int? = nil,
        outputExcerpt: String = "",
        conversationID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.hostID = hostID
        self.hostName = hostName
        self.hostTarget = hostTarget
        self.tool = tool
        self.command = command
        self.proposedCommand = proposedCommand
        self.reason = reason
        self.decision = decision
        self.decisionDetail = decisionDetail
        self.exitStatus = exitStatus
        self.durationMilliseconds = durationMilliseconds
        self.outputExcerpt = outputExcerpt
        self.conversationID = conversationID
    }

    @MainActor
    public init(_ entry: AgentAuditEntry) {
        self.init(
            id: entry.uuid, timestamp: entry.timestamp, source: entry.source, hostID: entry.hostID,
            hostName: entry.hostName, hostTarget: entry.hostTarget, tool: entry.tool, command: entry.command,
            proposedCommand: entry.proposedCommand, reason: entry.reason, decision: entry.decision,
            decisionDetail: entry.decisionDetail, exitStatus: entry.exitStatus,
            durationMilliseconds: entry.durationMilliseconds, outputExcerpt: entry.outputExcerpt,
            conversationID: entry.conversationID)
    }

    /// Pretty JSON with ISO 8601 dates, newest first as given.
    public static func exportJSON(_ records: [AgentAuditRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }
}
