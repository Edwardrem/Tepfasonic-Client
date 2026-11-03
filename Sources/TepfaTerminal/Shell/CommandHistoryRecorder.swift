import Foundation
import TepfaCore

/// A command the session saw start or finish.
public struct CommandRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var command: String
    public var hostID: UUID?
    public var hostName: String
    public var hostTarget: String
    public var startedAt: Date
    public var workingDirectory: String?
    public var source: CommandHistorySource
    public var finishedAt: Date?
    public var exitStatus: Int?

    public init(
        id: UUID = UUID(), command: String, hostID: UUID?, hostName: String, hostTarget: String,
        startedAt: Date = .now, workingDirectory: String? = nil, source: CommandHistorySource
    ) {
        self.id = id
        self.command = command
        self.hostID = hostID
        self.hostName = hostName
        self.hostTarget = hostTarget
        self.startedAt = startedAt
        self.workingDirectory = workingDirectory
        self.source = source
    }
}

/// Receives commands as sessions observe them. The app stores them in SwiftData.
@MainActor
public protocol CommandHistoryRecorder: AnyObject {
    func commandStarted(_ record: CommandRecord)
    func commandFinished(id: UUID, exitStatus: Int?, at date: Date)
}

/// Keeps records in memory; used by tests and as a default.
@MainActor
public final class InMemoryCommandHistoryRecorder: CommandHistoryRecorder {
    public private(set) var records: [CommandRecord] = []

    public init() {}

    public func commandStarted(_ record: CommandRecord) {
        records.append(record)
    }

    public func commandFinished(id: UUID, exitStatus: Int?, at date: Date) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].exitStatus = exitStatus
        records[index].finishedAt = date
    }
}
