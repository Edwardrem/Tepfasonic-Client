import Foundation

/// One turn of a conversation, provider-neutral so transcripts can be saved
/// and replayed to either kind of model.
public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public var id: UUID
    public var role: Role
    public var blocks: [AgentContentBlock]
    public var createdAt: Date
    /// The model that produced an assistant turn (as reported by the API).
    public var model: String?

    public init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], createdAt: Date = .now, model: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.createdAt = createdAt
        self.model = model
    }

    public static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, blocks: [.text(text)])
    }

    /// The visible text of the turn.
    public var text: String {
        blocks.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap { if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) } else { return nil } }
    }
}

public enum AgentContentBlock: Codable, Sendable, Equatable {
    case text(String)
    /// `text` is the summary shown to the user; `signature` lets the block be
    /// replayed to the same model. Unsigned blocks are not sent back.
    case thinking(text: String, signature: String?)
    case redactedThinking(data: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, text, signature, data, id, name, input, toolUseID = "tool_use_id", content, isError = "is_error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(text: try container.decodeIfPresent(String.self, forKey: .text) ?? "", signature: try container.decodeIfPresent(String.self, forKey: .signature))
        case "redacted_thinking":
            self = .redactedThinking(data: try container.decode(String.self, forKey: .data))
        case "tool_use":
            self = .toolUse(id: try container.decode(String.self, forKey: .id), name: try container.decode(String.self, forKey: .name), input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:]))
        case "tool_result":
            self = .toolResult(toolUseID: try container.decode(String.self, forKey: .toolUseID), content: try container.decodeIfPresent(String.self, forKey: .content) ?? "", isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown block type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let text, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(signature, forKey: .signature)
        case .redactedThinking(let data):
            try container.encode("redacted_thinking", forKey: .type)
            try container.encode(data, forKey: .data)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }
}

public enum AgentTranscript {
    public static func encode(_ messages: [AgentMessage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(messages)
    }

    public static func decode(_ data: Data) throws -> [AgentMessage] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentMessage].self, from: data)
    }
}
