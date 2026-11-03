import Foundation
import SwiftData

/// How a history entry was captured.
public enum CommandHistorySource: String, Codable, Sendable {
    /// From OSC 133 shell integration: exact text and exit status.
    case shellIntegration
    /// Reconstructed from keystrokes; no exit status.
    case typed
}

/// One command the user ran, across every host.
@Model
public final class CommandHistoryEntry {
    @Attribute(.unique) public var uuid: UUID
    public var command: String
    public var hostID: UUID?
    public var hostName: String
    public var hostTarget: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitStatus: Int?
    public var workingDirectory: String?
    public var sourceRaw: String

    public init(
        uuid: UUID = UUID(),
        command: String,
        hostID: UUID?,
        hostName: String,
        hostTarget: String,
        startedAt: Date = .now,
        workingDirectory: String? = nil,
        source: CommandHistorySource
    ) {
        self.uuid = uuid
        self.command = command
        self.hostID = hostID
        self.hostName = hostName
        self.hostTarget = hostTarget
        self.startedAt = startedAt
        self.finishedAt = nil
        self.exitStatus = nil
        self.workingDirectory = workingDirectory
        self.sourceRaw = source.rawValue
    }

    public var source: CommandHistorySource {
        get { CommandHistorySource(rawValue: sourceRaw) ?? .typed }
        set { sourceRaw = newValue.rawValue }
    }

    public var succeeded: Bool? {
        exitStatus.map { $0 == 0 }
    }
}
