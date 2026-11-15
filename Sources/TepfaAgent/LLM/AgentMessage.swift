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

    /// A user turn with files: attachments come first so the model reads them before the question.
    public static func user(_ text: String, attachments: [AgentAttachment]) -> AgentMessage {
        var blocks: [AgentContentBlock] = attachments.map { .attachment($0) }
        if !text.isEmpty { blocks.append(.text(text)) }
        return AgentMessage(role: .user, blocks: blocks)
    }

    public var attachments: [AgentAttachment] {
        blocks.compactMap { if case .attachment(let file) = $0 { return file } else { return nil } }
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
    /// A file the user attached (user turns only).
    case attachment(AgentAttachment)

    private enum CodingKeys: String, CodingKey {
        case type, text, signature, data, id, name, input, toolUseID = "tool_use_id", content, isError = "is_error", file
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
        case "attachment":
            self = .attachment(try container.decode(AgentAttachment.self, forKey: .file))
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
        case .attachment(let file):
            try container.encode("attachment", forKey: .type)
            try container.encode(file, forKey: .file)
        }
    }
}

public enum AgentTranscript {
    /// The result text for a tool call that never finished: the reply was cut
    /// off or interrupted before the tool could run.
    public static let interruptedToolCallText = "This tool call did not finish: the reply was interrupted before it ran."
    /// The result text for a call whose result was lost with the app or the
    /// conversation, so it may in fact have run.
    public static let missingToolResultText = "No result was recorded for this tool call: the app was closed or the conversation was switched while it was in flight. It may have run. Check the current state before repeating it."
    /// The result text when the output limit ended the reply before the call was answered.
    public static let maxTokensToolCallText = "The reply reached the model's output limit, so this tool call did not run. If its input was cut off, send it again in smaller parts."
    /// The result text for a call whose streamed input never parsed, so it cannot be run.
    public static let cutOffInputToolCallText = "This tool call's input was not valid JSON (it may have been cut off), so it did not run. Send it again with valid JSON, in smaller parts if it was large."

    /// Returns a transcript the Messages API accepts: every assistant turn with
    /// tool calls is answered by the very next user turn, with exactly one result
    /// per call in call order, results before any other block, and results that
    /// answer nothing dropped. Missing results are added as errors that warn the
    /// call may have run; a call with an empty id (a half-streamed block) or a
    /// repeated id is dropped. Healthy history is returned unchanged, so the
    /// function is idempotent.
    public static func repaired(_ messages: [AgentMessage]) -> [AgentMessage] {
        var out: [AgentMessage] = []
        // The call ids of the immediately preceding assistant turn, still unanswered.
        var pending: [String] = []

        for message in messages {
            if message.role == .assistant {
                if !pending.isEmpty {
                    out.append(answering(pending))
                    pending = []
                }
                let copy = withoutInvalidToolUses(message)
                // A turn that only held half-streamed calls has nothing left to show.
                guard !copy.blocks.isEmpty || message.blocks.isEmpty else { continue }
                out.append(copy)
                pending = copy.toolUses.map(\.id)
            } else {
                var seen = Set<String>()
                var answers: [String: AgentContentBlock] = [:]
                var others: [AgentContentBlock] = []
                for block in message.blocks {
                    if case .toolResult(let id, _, _) = block {
                        guard pending.contains(id), seen.insert(id).inserted else { continue }
                        answers[id] = block
                    } else {
                        others.append(block)
                    }
                }
                // Results lead the turn, in the order of the calls they answer.
                var blocks: [AgentContentBlock] = pending.map { id in
                    answers[id] ?? .toolResult(toolUseID: id, content: missingToolResultText, isError: true)
                }
                blocks.append(contentsOf: others)
                pending = []
                // A turn whose only blocks were orphaned results goes too.
                guard !blocks.isEmpty || message.blocks.isEmpty else { continue }
                var copy = message
                copy.blocks = blocks
                out.append(copy)
            }
        }
        // A reply interrupted after its calls still needs an answer at the end.
        if !pending.isEmpty { out.append(answering(pending)) }
        return out
    }

    /// Drops calls that cannot be answered: a half-streamed block with no id,
    /// and any later call that repeats an id already used in the same turn.
    static func withoutInvalidToolUses(_ message: AgentMessage) -> AgentMessage {
        guard message.role == .assistant else { return message }
        var seen = Set<String>()
        var copy = message
        copy.blocks = message.blocks.filter { block in
            guard case .toolUse(let id, _, _) = block else { return true }
            return !id.isEmpty && seen.insert(id).inserted
        }
        return copy
    }

    private static func answering(_ ids: [String]) -> AgentMessage {
        AgentMessage(role: .user, blocks: ids.map {
            .toolResult(toolUseID: $0, content: missingToolResultText, isError: true)
        })
    }

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

    /// The conversation as plain text for the clipboard: each visible turn
    /// under "You" or "Claude", attachments by name and tool calls as one line.
    /// Thinking and tool results are left out.
    public static func plainText(_ messages: [AgentMessage]) -> String {
        var turns: [String] = []
        for message in messages {
            var lines: [String] = []
            for block in message.blocks {
                switch block {
                case .text(let text):
                    lines.append(text)
                case .attachment(let file):
                    lines.append("[Attached: \(file.fileName)]")
                case .toolUse(_, let name, let input):
                    let detail = input["command"]?.stringValue ?? input["path"]?.stringValue ?? input["remote_path"]?.stringValue ?? input["file_name"]?.stringValue
                    let host = input["host"]?.stringValue.map { " on \($0)" } ?? ""
                    lines.append("[\(name)\(host)\(detail.map { ": \($0)" } ?? "")]")
                case .thinking, .redactedThinking, .toolResult:
                    break
                }
            }
            guard !lines.isEmpty else { continue }
            let body = lines.joined(separator: "\n")
            // Consecutive assistant messages (a reply split by tool calls) read as one turn.
            if message.role == .assistant, let last = turns.last, last.hasPrefix("Claude:\n") {
                turns[turns.count - 1] = last + "\n" + body
            } else {
                turns.append((message.role == .user ? "You:\n" : "Claude:\n") + body)
            }
        }
        return turns.joined(separator: "\n\n")
    }
}
