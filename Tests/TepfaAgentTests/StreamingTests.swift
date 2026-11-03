import Foundation
import Testing
@testable import TepfaAgent

@Suite("SSE parsing")
struct SSEParserTests {
    @Test func eventsSplitAcrossChunks() {
        var parser = SSEParser()
        var events = parser.feed("event: message_start\ndata: {\"a\":")
        #expect(events.isEmpty)
        events += parser.feed("1}\n\n: comment\r\ndata: first\r\ndata: second\r\n\r\n")
        #expect(events == [
            SSEParser.Event(name: "message_start", data: "{\"a\":1}"),
            SSEParser.Event(name: nil, data: "first\nsecond"),
        ])
        events = parser.feed("data: tail")
        #expect(events.isEmpty)
        #expect(parser.finish() == SSEParser.Event(name: nil, data: "tail"))
    }
}

@Suite("Anthropic stream assembly")
struct AnthropicAssemblerTests {
    private func events(_ script: [(String, String)]) throws -> [LLMStreamEvent] {
        var assembler = AnthropicStreamAssembler()
        var out: [LLMStreamEvent] = []
        for (name, data) in script {
            out += try assembler.handle(SSEParser.Event(name: name, data: data))
        }
        return out
    }

    @Test func textThinkingAndToolUse() throws {
        let out = try events([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":120,"cache_read_input_tokens":100}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me check disk space."}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"now."}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_command","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"host\":\"web\",\"comm"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"and\":\"df -h\",\"reason\":\"disk\"}"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        guard case .done(let response)? = out.last else { Issue.record("no done event"); return }
        #expect(response.stopReason == .toolUse)
        #expect(response.model == "claude-opus-5-5")
        #expect(response.usage == LLMUsage(inputTokens: 120, outputTokens: 42, cacheReadTokens: 100))
        #expect(response.message.blocks == [
            .thinking(text: "Let me check disk space.", signature: "sig123"),
            .text("Checking now."),
            .toolUse(id: "toolu_1", name: "run_command", input: ["host": "web", "command": "df -h", "reason": "disk"]),
        ])
        let textDeltas = out.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        #expect(textDeltas == ["Checking ", "now."])
        #expect(out.contains { if case .toolUseStarted(let name) = $0 { return name == "run_command" } else { return false } })
    }

    @Test func refusalAndFallback() throws {
        let out = try events([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-4-8","usage":{"input_tokens":5,"iterations":[{"type":"fallback_message","model":"claude-opus-4-8"}]}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Sorry"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":1}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        guard case .done(let response)? = out.last else { Issue.record("no done event"); return }
        #expect(response.stopReason == .refusal)
        #expect(response.refusalCategory == "cyber")
        #expect(response.servedByFallback)
        #expect(response.message.text == "Sorry")
    }

    @Test func errorEventThrows() {
        var assembler = AnthropicStreamAssembler()
        #expect(throws: LLMError.api(type: "overloaded_error", message: "Overloaded")) {
            _ = try assembler.handle(SSEParser.Event(name: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        }
    }

    @Test func requestBodyShape() throws {
        let provider = AnthropicProvider(apiKey: "k", model: "claude-opus-5-5", effort: "high")
        let messages: [AgentMessage] = [
            .user("hello"),
            AgentMessage(role: .assistant, blocks: [.thinking(text: "unsigned", signature: nil), .thinking(text: "signed", signature: "s"), .text(""), .toolUse(id: "t1", name: "list_hosts", input: [:])]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseID: "t1", content: "2 hosts", isError: false)]),
        ]
        let body = provider.requestBody(LLMRequest(system: "sys", messages: messages, tools: AgentTools.all))
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["stream"]?.boolValue == true)
        #expect(body["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(body["thinking"]?["display"]?.stringValue == "summarized")
        #expect(body["output_config"]?["effort"]?.stringValue == "high")
        #expect(body["fallbacks"]?.stringValue == "default")
        #expect(body["system"]?.arrayValue?.first?["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(body["tools"]?.arrayValue?.count == AgentTools.all.count)
        let sent = body["messages"]?.arrayValue ?? []
        #expect(sent.count == 3)
        let assistant = sent[1]["content"]?.arrayValue ?? []
        #expect(assistant.map { $0["type"]?.stringValue } == ["thinking", "tool_use"], "unsigned thinking and empty text are not replayed")
        #expect(sent[2]["content"]?.arrayValue?.first?["tool_use_id"]?.stringValue == "t1")

        let haiku = AnthropicProvider(apiKey: "k", model: "claude-haiku-5-5").requestBody(LLMRequest(system: "s", messages: [.user("x")], tools: []))
        #expect(haiku["fallbacks"] == nil)
        #expect(haiku["tools"] == nil)
        #expect(haiku["output_config"] == nil)
        let legacy = AnthropicProvider(apiKey: "k", model: "claude-haiku-4-5").requestBody(LLMRequest(system: "s", messages: [.user("x")], tools: []))
        #expect(legacy["thinking"] == nil)
    }
}

@Suite("OpenAI-compatible stream assembly")
struct OpenAIAssemblerTests {
    @Test func toolCallsAcrossChunks() throws {
        var assembler = OpenAIStreamAssembler(model: "llama")
        var out: [LLMStreamEvent] = []
        for data in [
            #"{"id":"c1","model":"llama3.3","choices":[{"index":0,"delta":{"role":"assistant","content":"I'll "},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"look."},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"reasoning_content":"thinking…"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run_command","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"host\":\"db\","}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"command\":\"uptime\",\"reason\":\"load\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":7}}"#,
            "[DONE]",
        ] {
            out += try assembler.handle(SSEParser.Event(name: nil, data: data))
        }
        guard case .done(let response)? = out.last else { Issue.record("no done"); return }
        #expect(response.stopReason == .toolUse)
        #expect(response.model == "llama3.3")
        #expect(response.usage.inputTokens == 10 && response.usage.outputTokens == 7)
        #expect(response.message.blocks == [
            .thinking(text: "thinking…", signature: nil),
            .text("I'll look."),
            .toolUse(id: "call_1", name: "run_command", input: ["host": "db", "command": "uptime", "reason": "load"]),
        ])
    }

    @Test func requestBodyShape() {
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "", model: "llama3.3")
        let messages: [AgentMessage] = [
            .user("hi"),
            AgentMessage(role: .assistant, blocks: [.text("checking"), .toolUse(id: "call_1", name: "list_hosts", input: [:])]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseID: "call_1", content: "none", isError: true)]),
        ]
        let body = provider.requestBody(LLMRequest(system: "sys", messages: messages, tools: AgentTools.all))
        let sent = body["messages"]?.arrayValue ?? []
        #expect(sent.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool"])
        #expect(sent[2]["tool_calls"]?.arrayValue?.first?["function"]?["name"]?.stringValue == "list_hosts")
        #expect(sent[3]["content"]?.stringValue == "Error: none")
        #expect(body["tools"]?.arrayValue?.first?["type"]?.stringValue == "function")
        #expect(body["tool_choice"]?.stringValue == "auto")
    }
}

@Suite("Transcript")
struct TranscriptTests {
    @Test func roundTrip() throws {
        let messages: [AgentMessage] = [
            .user("hello"),
            AgentMessage(role: .assistant, blocks: [.thinking(text: "t", signature: "s"), .redactedThinking(data: "d"), .text("x"), .toolUse(id: "1", name: "run_command", input: ["host": "a", "n": 2, "ok": true, "list": [1, "b"]])]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseID: "1", content: "out", isError: false)]),
        ]
        let data = try AgentTranscript.encode(messages)
        let decoded = try AgentTranscript.decode(data)
        #expect(decoded.map(\.blocks) == messages.map(\.blocks))
        #expect(decoded.map(\.role) == messages.map(\.role))
        #expect(try AgentTranscript.decode(Data()).isEmpty)
    }

    @Test func jsonValueNumbers() throws {
        let value = try JSONValue.parse(#"{"i":3,"f":2.5,"big":12345678901234,"neg":-1}"#)
        #expect(value["i"]?.intValue == 3)
        #expect(value["f"]?.doubleValue == 2.5)
        #expect(value.text == #"{"big":12345678901234,"f":2.5,"i":3,"neg":-1}"#)
    }
}
