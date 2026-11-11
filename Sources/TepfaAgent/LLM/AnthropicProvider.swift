import Foundation

/// Streams from the Anthropic Messages API over raw HTTP (there is no
/// official Swift SDK). Adaptive thinking is on with a summarised display,
/// and policy declines fall back server-side on the models that support it.
public struct AnthropicProvider: LLMProvider {
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Models the `fallbacks: "default"` parameter is accepted on.
    public static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    public var apiKey: String
    public var model: String
    public var effort: String?
    public var baseURL: URL
    public var maxTokens: Int
    public var session: URLSession

    public init(apiKey: String, model: String, effort: String? = nil, baseURL: URL = URL(string: "https://api.anthropic.com")!, maxTokens: Int = 16_000, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.session = session
    }

    public var displayName: String { "Anthropic" }
    public var modelName: String { model }

    /// Older models take a thinking budget instead of adaptive thinking; they get no thinking here.
    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        let legacy = ["claude-3", "claude-opus-4-0", "claude-opus-4-1", "claude-opus-4-5", "claude-sonnet-4-0", "claude-sonnet-4-5", "claude-haiku-4-5", "claude-sonnet-4-2"]
        return !legacy.contains { model.hasPrefix($0) }
    }

    public func requestBody(_ request: LLMRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(true),
            "system": .array([.object(["type": "text", "text": .string(request.system), "cache_control": ["type": "ephemeral"]])]),
            "messages": Self.messagesJSON(request.messages),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { .object(["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema]) })
        }
        if Self.supportsAdaptiveThinking(model) {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if let effort, !effort.isEmpty {
            body["output_config"] = ["effort": .string(effort)]
        }
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    static func messagesJSON(_ messages: [AgentMessage]) -> JSONValue {
        var out: [JSONValue] = []
        for message in messages {
            var blocks: [JSONValue] = []
            for block in message.blocks {
                switch block {
                case .text(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
                case .thinking(let text, let signature):
                    if let signature, message.role == .assistant { blocks.append(["type": "thinking", "thinking": .string(text), "signature": .string(signature)]) }
                case .redactedThinking(let data):
                    if message.role == .assistant { blocks.append(["type": "redacted_thinking", "data": .string(data)]) }
                case .toolUse(let id, let name, let input):
                    blocks.append(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
                case .toolResult(let toolUseID, let content, let isError):
                    blocks.append(["type": "tool_result", "tool_use_id": .string(toolUseID), "content": .string(content), "is_error": .bool(isError)])
                case .attachment(let file):
                    if message.role == .user { blocks.append(attachmentBlock(file)) }
                }
            }
            guard !blocks.isEmpty else { continue }
            out.append(["role": .string(message.role.rawValue), "content": .array(blocks)])
        }
        return .array(out)
    }

    /// Images go as image blocks, PDFs and text files as document blocks (text
    /// files with a plain-text source), all read from the app's copy now.
    static func attachmentBlock(_ file: AgentAttachment) -> JSONValue {
        guard let data = try? file.data() else {
            return ["type": "text", "text": .string("[The attachment \(file.fileName) is no longer available on this Mac.]")]
        }
        switch file.kind {
        case .image:
            return ["type": "image", "source": ["type": "base64", "media_type": .string(file.mediaType), "data": .string(data.base64EncodedString())]]
        case .pdf:
            return ["type": "document", "title": .string(file.fileName), "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64EncodedString())]]
        case .text:
            return ["type": "document", "title": .string(file.fileName), "source": ["type": "text", "media_type": "text/plain", "data": .string(String(decoding: data, as: UTF8.self))]]
        }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: LLMRequest, continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async throws {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if Self.fallbackModels.contains(model) {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = requestBody(request).data()
        urlRequest.timeoutInterval = 600

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("not an HTTP response") }
        if http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            throw Self.error(status: http.statusCode, body: body)
        }

        var parser = SSEParser()
        var assembler = AnthropicStreamAssembler()
        var line = Data()
        func handle(_ events: [SSEParser.Event]) throws {
            for event in events {
                for out in try assembler.handle(event) { continuation.yield(out) }
            }
        }
        for try await byte in bytes {
            line.append(byte)
            if byte == 0x0A {
                try handle(parser.feed(String(decoding: line, as: UTF8.self)))
                line.removeAll(keepingCapacity: true)
            }
        }
        if !line.isEmpty { try handle(parser.feed(String(decoding: line, as: UTF8.self))) }
        if let last = parser.finish() { try handle([last]) }
        if let response = assembler.finishIfNeeded() { continuation.yield(.done(response)) }
    }

    static func error(status: Int, body: Data) -> LLMError {
        if let json = try? JSONValue.parse(body), let error = json["error"], let message = error["message"]?.stringValue {
            return .api(type: error["type"]?.stringValue ?? "http_\(status)", message: message)
        }
        return .httpStatus(status, String(decoding: body.prefix(300), as: UTF8.self))
    }
}

/// Turns the Messages API stream into blocks and a final response.
struct AnthropicStreamAssembler {
    private enum Partial {
        case text(String)
        case thinking(text: String, signature: String)
        case redacted(String)
        case toolUse(id: String, name: String, json: String)
        case ignored
    }

    private var model: String?
    private var blocks: [Int: Partial] = [:]
    private var order: [Int] = []
    private var stopReason: LLMStopReason = .other
    private var usage = LLMUsage()
    private var refusalCategory: String?
    private var servedByFallback = false
    private var finished = false
    private var started = false

    mutating func handle(_ event: SSEParser.Event) throws -> [LLMStreamEvent] {
        guard !event.data.isEmpty else { return [] }
        let json = try JSONValue.parse(event.data)
        let type = event.name ?? json["type"]?.stringValue ?? ""
        switch type {
        case "message_start":
            model = json["message"]?["model"]?.stringValue
            if let usage = json["message"]?["usage"] { apply(usage) }
            started = true
            return [.started(model: model)]
        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else { return [] }
            order.append(index)
            switch block["type"]?.stringValue {
            case "text": blocks[index] = .text(block["text"]?.stringValue ?? "")
            case "thinking": blocks[index] = .thinking(text: block["thinking"]?.stringValue ?? "", signature: block["signature"]?.stringValue ?? "")
            case "redacted_thinking": blocks[index] = .redacted(block["data"]?.stringValue ?? "")
            case "tool_use":
                blocks[index] = .toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "", json: "")
                return [.toolUseStarted(name: block["name"]?.stringValue ?? "")]
            case "fallback":
                servedByFallback = true
                blocks[index] = .ignored
            default: blocks[index] = .ignored
            }
            return []
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"], let current = blocks[index] else { return [] }
            switch (delta["type"]?.stringValue, current) {
            case ("text_delta", .text(let text)):
                let piece = delta["text"]?.stringValue ?? ""
                blocks[index] = .text(text + piece)
                return [.textDelta(piece)]
            case ("thinking_delta", .thinking(let text, let signature)):
                let piece = delta["thinking"]?.stringValue ?? ""
                blocks[index] = .thinking(text: text + piece, signature: signature)
                return [.thinkingDelta(piece)]
            case ("signature_delta", .thinking(let text, let signature)):
                blocks[index] = .thinking(text: text, signature: signature + (delta["signature"]?.stringValue ?? ""))
            case ("input_json_delta", .toolUse(let id, let name, let partial)):
                blocks[index] = .toolUse(id: id, name: name, json: partial + (delta["partial_json"]?.stringValue ?? ""))
            default: break
            }
            return []
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                stopReason = Self.stopReason(reason)
                if reason == "refusal" { refusalCategory = json["delta"]?["stop_details"]?["category"]?.stringValue ?? "unspecified" }
            }
            if let usage = json["usage"] { apply(usage) }
            return []
        case "message_stop":
            finished = true
            return [.done(buildResponse())]
        case "error":
            throw LLMError.api(type: json["error"]?["type"]?.stringValue ?? "error", message: json["error"]?["message"]?.stringValue ?? "The API reported an error.")
        default:
            return []
        }
    }

    /// A response for a stream that ended without `message_stop` (connection dropped).
    mutating func finishIfNeeded() -> LLMResponse? {
        guard started, !finished else { return nil }
        finished = true
        return buildResponse()
    }

    private mutating func apply(_ usage: JSONValue) {
        if let value = usage["input_tokens"]?.intValue { self.usage.inputTokens = value }
        if let value = usage["output_tokens"]?.intValue { self.usage.outputTokens = value }
        if let value = usage["cache_read_input_tokens"]?.intValue { self.usage.cacheReadTokens = value }
        if let value = usage["cache_creation_input_tokens"]?.intValue { self.usage.cacheWriteTokens = value }
        if let iterations = usage["iterations"]?.arrayValue, iterations.contains(where: { $0["type"]?.stringValue == "fallback_message" }) {
            servedByFallback = true
        }
    }

    private func buildResponse() -> LLMResponse {
        var content: [AgentContentBlock] = []
        for index in order {
            switch blocks[index] {
            case .text(let text)?: content.append(.text(text))
            case .thinking(let text, let signature)?: content.append(.thinking(text: text, signature: signature.isEmpty ? nil : signature))
            case .redacted(let data)?: content.append(.redactedThinking(data: data))
            case .toolUse(let id, let name, let json)?:
                let input = (try? JSONValue.parse(json.isEmpty ? "{}" : json)) ?? .object(["_invalid_json": .string(json)])
                content.append(.toolUse(id: id, name: name, input: input))
            default: break
            }
        }
        let message = AgentMessage(role: .assistant, blocks: content, model: model)
        return LLMResponse(message: message, stopReason: stopReason, model: model, usage: usage, refusalCategory: refusalCategory, servedByFallback: servedByFallback)
    }

    static func stopReason(_ raw: String) -> LLMStopReason {
        switch raw {
        case "end_turn", "stop_sequence": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "refusal": .refusal
        case "pause_turn": .pauseTurn
        default: .other
        }
    }
}
