import Foundation
import SwiftData

/// A saved chat with the agent. The transcript is JSON produced by the agent
/// library so tool calls and thinking blocks replay exactly.
@Model
public final class AgentConversation {
    @Attribute(.unique) public var uuid: UUID
    public var title: String
    /// The host the conversation was started for, or nil for "all hosts".
    public var hostID: UUID?
    public var groupID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var transcript: Data
    /// Provider and model that produced the latest assistant turn.
    public var model: String?

    public init(uuid: UUID = UUID(), title: String, hostID: UUID? = nil, groupID: UUID? = nil, transcript: Data = Data(), model: String? = nil) {
        self.uuid = uuid
        self.title = title
        self.hostID = hostID
        self.groupID = groupID
        self.createdAt = .now
        self.updatedAt = .now
        self.transcript = transcript
        self.model = model
    }
}
