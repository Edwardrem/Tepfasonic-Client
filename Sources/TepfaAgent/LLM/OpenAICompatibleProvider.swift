import Foundation

/// Streams from any server that speaks the OpenAI chat-completions API with
/// tool calling: a local model behind Ollama, vLLM or LM Studio, or a hosted one.
public struct OpenAICompatibleProvider: LLMProvider {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var session: URLSession

    public init(baseURL: URL, apiKey: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public var displayName: String { baseURL.host ?? "endpoint" }
    public var modelName: String { model }

    public func requestBody(_ request: LLMRequest) -> JSONValue {
        var messages: [JSONValue] = [["role": "system", "content": .string(request.system)]]
        messages.append(contentsOf: Self.messagesJSON(request.messages))
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "messages": .array(messages),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                .object(["type": "function", "function": .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema])])
            })
            body["tool_choice"] = "auto"
        }
        return .object(body)
    }

    static func messagesJSON(_ messages: [AgentMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .user:
                var text = ""
                var parts: [JSONValue] = []
                for block in message.blocks {
                    switch block {
                    case .text(let value): text += value
                    case .toolResult(let toolUseID, let content, let isError):
                        out.append(["role": "tool", "tool_call_id": .string(toolUseID), "content": .string(isError ? "Error: \(content)" : content)])
                    case .attachment(let file):
                        parts.append(attachmentPart(file))
                    default: break
                    }
                }
                if !parts.isEmpty {
                    if !text.isEmpty { parts.append(["type": "text", "text": .string(text)]) }
                    out.append(["role": "user", "content": .array(parts)])
                } else if !text.isEmpty {
                    out.append(["role": "user", "content": .string(text)])
                }
            case .assistant:
                var text = ""
                var calls: [JSONValue] = []
                for block in message.blocks {
                    switch block {
                    case .text(let value): text += value
                    case .toolUse(let id, let name, let input):
                        calls.append(["id": .string(id), "type": "function", "function": .object(["name": .string(name), "arguments": .string(input.text)])])
                    default: break
                    }
                }
                var entry: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
                if !calls.isEmpty { entry["tool_calls"] = .array(calls) }
                out.append(.object(entry))
            }
        }
        return out
    }

    /// Images go as data-URI `image_url` parts; PDFs are sent as their text, since
    /// chat-completions endpoints have no document type; text files go inline.
    static func attachmentPart(_ file: AgentAttachment) -> JSONValue {
        guard let data = try? file.data() else {
            return ["type": "text", "text": .string("[The attachment \(file.fileName) is no longer available on this Mac.]")]
        }
        switch file.kind {
        case .image:
            return ["type": "image_url", "image_url": ["url": .string("data:\(file.mediaType);base64," + data.base64EncodedString())]]
        case .pdf:
            let text = PDFText.extract(from: data) ?? "[no text could be extracted from this PDF]"
            return ["type": "text", "text": .string("<attachment name=\"\(file.fileName)\" type=\"application/pdf\">\n\(text)\n</attachment>")]
        case .text:
            return ["type": "text", "text": .string("<attachment name=\"\(file.fileName)\" type=\"\(file.mediaType)\">\n\(String(decoding: data, as: UTF8.self))\n</attachment>")]
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
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = requestBody(request).data()
        urlRequest.timeoutInterval = 600

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("not an HTTP response") }
        if http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            throw AnthropicProvider.error(status: http.statusCode, body: body)
        }

        var parser = SSEParser()
        var assembler = OpenAIStreamAssembler(model: model)
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
}

struct OpenAIStreamAssembler {
    private struct Call { var id: String; var name: String; var arguments: String }

    private var model: String?
    private var text = ""
    private var reasoning = ""
    private var calls: [Int: Call] = [:]
    private var finishReason: String?
    private var usage = LLMUsage()
    private var finished = false
    private var started = false

    init(model: String) {
        self.model = model
    }

    mutating func handle(_ event: SSEParser.Event) throws -> [LLMStreamEvent] {
        let data = event.data.trimmingCharacters(in: .whitespaces)
        guard !data.isEmpty else { return [] }
        if data == "[DONE]" {
            guard !finished else { return [] }
            finished = true
            return [.done(buildResponse())]
        }
        let json = try JSONValue.parse(data)
        if let error = json["error"] {
            throw LLMError.api(type: error["type"]?.stringValue ?? "error", message: error["message"]?.stringValue ?? "The endpoint reported an error.")
        }
        var events: [LLMStreamEvent] = []
        if !started {
            started = true
            if let served = json["model"]?.stringValue { model = served }
            events.append(.started(model: model))
        }
        if let usage = json["usage"] {
            if let value = usage["prompt_tokens"]?.intValue { self.usage.inputTokens = value }
            if let value = usage["completion_tokens"]?.intValue { self.usage.outputTokens = value }
        }
        guard let choice = json["choices"]?.arrayValue?.first else { return events }
        if let delta = choice["delta"] {
            if let piece = delta["content"]?.stringValue, !piece.isEmpty {
                text += piece
                events.append(.textDelta(piece))
            }
            if let piece = (delta["reasoning_content"] ?? delta["reasoning"])?.stringValue, !piece.isEmpty {
                reasoning += piece
                events.append(.thinkingDelta(piece))
            }
            for call in delta["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? calls.count
                var current = calls[index] ?? Call(id: "", name: "", arguments: "")
                if let id = call["id"]?.stringValue, !id.isEmpty { current.id = id }
                if let name = call["function"]?["name"]?.stringValue, !name.isEmpty {
                    if current.name.isEmpty { events.append(.toolUseStarted(name: name)) }
                    current.name += name
                }
                if let arguments = call["function"]?["arguments"]?.stringValue { current.arguments += arguments }
                calls[index] = current
            }
        }
        if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty { finishReason = reason }
        return events
    }

    mutating func finishIfNeeded() -> LLMResponse? {
        guard started, !finished else { return nil }
        finished = true
        return buildResponse()
    }

    private func buildResponse() -> LLMResponse {
        var blocks: [AgentContentBlock] = []
        if !reasoning.isEmpty { blocks.append(.thinking(text: reasoning, signature: nil)) }
        if !text.isEmpty { blocks.append(.text(text)) }
        for index in calls.keys.sorted() {
            let call = calls[index]!
            let input = (try? JSONValue.parse(call.arguments.isEmpty ? "{}" : call.arguments)) ?? .object(["_invalid_json": .string(call.arguments)])
            blocks.append(.toolUse(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name, input: input))
        }
        let stop: LLMStopReason
        switch finishReason {
        case "tool_calls", "function_call": stop = .toolUse
        case "length": stop = .maxTokens
        case "content_filter": stop = .refusal
        case "stop", nil: stop = calls.isEmpty ? .endTurn : .toolUse
        default: stop = .other
        }
        return LLMResponse(message: AgentMessage(role: .assistant, blocks: blocks, model: model), stopReason: stop, model: model, usage: usage)
    }
}
