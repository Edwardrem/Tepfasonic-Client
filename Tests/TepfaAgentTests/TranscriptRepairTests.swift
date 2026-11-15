import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

// MARK: - Helpers

/// The rule the Messages API enforces (and OpenAI-style endpoints expect too):
/// every assistant turn's tool calls are answered at the start of the very next
/// user turn by exactly one result each, in call order, with no orphan or
/// duplicate results anywhere.
func toolPairingIsValid(_ messages: [AgentMessage]) -> Bool {
    for (index, message) in messages.enumerated() {
        switch message.role {
        case .assistant:
            let ids = message.toolUses.map(\.id)
            if ids.contains(where: \.isEmpty) { return false }
            guard !ids.isEmpty else { continue }
            guard index + 1 < messages.count, messages[index + 1].role == .user else { return false }
            let next = messages[index + 1]
            let resultIDs = next.blocks.compactMap { block -> String? in
                if case .toolResult(let id, _, _) = block { return id }
                return nil
            }
            guard resultIDs == ids else { return false }
            var sawOther = false
            for block in next.blocks {
                if case .toolResult = block {
                    if sawOther { return false }
                } else {
                    sawOther = true
                }
            }
        case .user:
            let previousIDs = index > 0 && messages[index - 1].role == .assistant
                ? messages[index - 1].toolUses.map(\.id)
                : []
            var seen = Set<String>()
            var sawOther = false
            for block in message.blocks {
                if case .toolResult(let id, _, _) = block {
                    guard !sawOther, previousIDs.contains(id), seen.insert(id).inserted else { return false }
                } else {
                    sawOther = true
                }
            }
        }
    }
    return true
}

/// Checks the wire form: an assistant message with `tool_use` blocks is followed
/// straight away by a user message whose leading blocks answer each id in order.
func anthropicPairingIsValid(_ json: JSONValue) -> Bool {
    let messages = json.arrayValue ?? []
    for (index, message) in messages.enumerated() {
        guard message["role"]?.stringValue == "assistant", let blocks = message["content"]?.arrayValue else { continue }
        let ids = blocks.compactMap { block -> String? in
            block["type"]?.stringValue == "tool_use" ? block["id"]?.stringValue : nil
        }
        if ids.contains(where: \.isEmpty) { return false }
        guard !ids.isEmpty else { continue }
        guard index + 1 < messages.count,
              messages[index + 1]["role"]?.stringValue == "user",
              let next = messages[index + 1]["content"]?.arrayValue else { return false }
        let resultIDs = next.compactMap { block -> String? in
            block["type"]?.stringValue == "tool_result" ? block["tool_use_id"]?.stringValue : nil
        }
        guard resultIDs == ids else { return false }
        var sawOther = false
        for block in next {
            if block["type"]?.stringValue == "tool_result" {
                if sawOther { return false }
            } else {
                sawOther = true
            }
        }
    }
    return true
}

/// Checks the OpenAI wire form: an assistant message with `tool_calls` is followed
/// by one `tool` message per id, in order, before any other message.
func openAIPairingIsValid(_ messages: [JSONValue]) -> Bool {
    for (index, message) in messages.enumerated() where message["role"]?.stringValue == "assistant" {
        guard let calls = message["tool_calls"]?.arrayValue, !calls.isEmpty else { continue }
        let ids = calls.compactMap { $0["id"]?.stringValue }
        if ids.contains(where: \.isEmpty) { return false }
        var answered: [String] = []
        var next = index + 1
        while next < messages.count, messages[next]["role"]?.stringValue == "tool" {
            answered.append(messages[next]["tool_call_id"]?.stringValue ?? "")
            next += 1
        }
        guard answered == ids else { return false }
    }
    return true
}

private func turn(_ role: AgentMessage.Role, _ blocks: [AgentContentBlock]) -> AgentMessage {
    AgentMessage(role: role, blocks: blocks)
}

private func call(_ id: String) -> AgentContentBlock {
    .toolUse(id: id, name: "run_command", input: ["host": "web-01", "command": "uptime", "reason": "load"])
}

private func answer(_ id: String, _ content: String = "ok") -> AgentContentBlock {
    .toolResult(toolUseID: id, content: content, isError: false)
}

private func interrupted(_ id: String) -> AgentContentBlock {
    .toolResult(toolUseID: id, content: AgentTranscript.interruptedToolCallText, isError: true)
}

/// What `AgentTranscript.repaired` synthesises: the result may have been lost, so
/// it must not claim the call never ran.
private func lost(_ id: String) -> AgentContentBlock {
    .toolResult(toolUseID: id, content: AgentTranscript.missingToolResultText, isError: true)
}

private func interruptedByLimit(_ id: String) -> AgentContentBlock {
    .toolResult(toolUseID: id, content: AgentTranscript.maxTokensToolCallText, isError: true)
}

/// A one-shot gate a test opens when it wants a held run to continue.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A flag set from a background task that the main-actor test can poll.
private actor Signal {
    private(set) var isSet = false

    func set() { isSet = true }
}

// MARK: - The repair function

@Suite("Transcript tool pairing repair")
@MainActor
struct TranscriptRepairTests {
    @Test func unansweredCallAtTheEndIsAnswered() {
        let original: [AgentMessage] = [.user("hi"), turn(.assistant, [.text("Let me look."), call("t1")])]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired.count == 3)
        #expect(repaired[1].blocks == original[1].blocks, "the reply stays in the history")
        #expect(repaired[2].role == .user)
        #expect(repaired[2].blocks == [lost("t1")])
    }

    @Test func unansweredCallBeforeUserTextIsAnsweredInThatTurn() {
        let original: [AgentMessage] = [.user("hi"), turn(.assistant, [call("t1")]), .user("carry on")]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired.count == 3)
        #expect(repaired[2].blocks == [lost("t1"), .text("carry on")])
    }

    @Test func partlyAnsweredCallGetsOnlyTheMissingResult() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [call("t1"), call("t2")]),
            turn(.user, [answer("t1", "done")]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired[2].blocks == [answer("t1", "done"), lost("t2")])
    }

    @Test func orphanResultIsDropped() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [.text("no calls here")]),
            turn(.user, [answer("t9"), .text("keep me")]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired.count == 3)
        #expect(repaired[2].blocks == [.text("keep me")])
    }

    @Test func turnLeftWithOnlyOrphanResultsIsRemoved() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [.text("no calls here")]),
            turn(.user, [answer("t9")]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired.count == 2)
    }

    @Test func duplicateResultIsDropped() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [call("t1")]),
            turn(.user, [answer("t1", "first"), answer("t1", "second")]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired[2].blocks == [answer("t1", "first")])
    }

    @Test func resultsAfterTextMoveToTheFront() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [call("t1")]),
            turn(.user, [.text("here is more"), answer("t1")]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired[2].blocks == [answer("t1"), .text("here is more")])
    }

    @Test func emptyIDToolUseIsDropped() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [.text("partial"), .toolUse(id: "", name: "", input: [:])]),
            .user("next"),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired.count == 3)
        #expect(repaired[1].blocks == [.text("partial")])
        #expect(repaired[2].blocks == [.text("next")], "an empty id answers nothing")
    }

    @Test func repeatedToolUseIDIsDropped() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [
                .toolUse(id: "t1", name: "run_command", input: ["command": "uptime"]),
                .toolUse(id: "t1", name: "read_file", input: ["path": "/etc/hosts"]),
            ]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired[1].toolUses.map(\.name) == ["run_command"], "only the first call for an id is kept")
        #expect(repaired[2].blocks == [lost("t1")])
    }

    @Test func turnOfOnlyAnEmptyIDToolUseIsRemoved() {
        let original: [AgentMessage] = [.user("hi"), turn(.assistant, [.toolUse(id: "", name: "run_command", input: [:])])]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired.map(\.role) == [.user])
    }

    @Test func severalToolUsesAreAnsweredInCallOrder() {
        let original: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [call("t1"), call("t2"), call("t3")]),
            turn(.user, [answer("t3", "c"), answer("t1", "a")]),
        ]
        let repaired = AgentTranscript.repaired(original)
        #expect(toolPairingIsValid(repaired))
        #expect(repaired[2].blocks == [answer("t1", "a"), lost("t2"), answer("t3", "c")])
    }

    @Test func validTranscriptIsUnchanged() {
        let valid: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [.text("checking"), call("t1")]),
            turn(.user, [answer("t1", "out")]),
            turn(.assistant, [.text("done")]),
        ]
        #expect(toolPairingIsValid(valid))
        #expect(AgentTranscript.repaired(valid) == valid, "healthy history keeps its ids and blocks")
    }

    @Test func repairIsIdempotent() {
        let broken: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [call("t1"), call("t2")]),
            .user("carry on"),
            turn(.assistant, [.text("partial"), .toolUse(id: "", name: "", input: [:])]),
        ]
        let once = AgentTranscript.repaired(broken)
        let twice = AgentTranscript.repaired(once)
        #expect(toolPairingIsValid(once))
        #expect(twice == once)
    }

    @Test func emptyTranscriptStaysEmpty() {
        #expect(AgentTranscript.repaired([]).isEmpty)
    }

    @Test func synthesisedResultDoesNotClaimTheCallNeverRan() {
        let repaired = AgentTranscript.repaired([.user("hi"), turn(.assistant, [call("t1")])])
        #expect(repaired.last?.blocks == [lost("t1")])
        #expect(repaired.last?.blocks.first != interrupted("t1"), "a lost result may have run")
        #expect(AgentTranscript.missingToolResultText.contains("may have run"))
    }

    @Test func resultTextsDoNotOverclaim() {
        #expect(AgentTranscript.maxTokensToolCallText.contains("reached the model's output limit"))
        #expect(AgentTranscript.maxTokensToolCallText.contains("If its input was cut off"))
        #expect(AgentTranscript.cutOffInputToolCallText.contains("was not valid JSON"))
        #expect(AgentTranscript.cutOffInputToolCallText.contains("may have been cut off"))
    }

    @Test func cutOffInputSentinelRoundTrips() {
        let raw = "{\"host\":\"web-01\""
        #expect(ToolCallInput.rawArguments(in: ToolCallInput.decoded(raw)) == raw)
        #expect(ToolCallInput.rawArguments(in: ToolCallInput.decoded("{}")) == nil)
        #expect(ToolCallInput.decoded(raw)[ToolCallInput.rawArgumentsKey]?.stringValue == raw)
    }

    // MARK: Providers

    @Test func anthropicWireFormAnswersEveryCall() {
        let broken: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [.text("checking"), call("t1"), call("t2")]),
            .user("carry on"),
            turn(.assistant, [call("t3")]),
        ]
        #expect(!toolPairingIsValid(broken), "the fixture is broken on disk")
        let json = AnthropicProvider.messagesJSON(broken)
        #expect(anthropicPairingIsValid(json))
        let sent = json.arrayValue ?? []
        let answered = sent[2]["content"]?.arrayValue?.map { $0["type"]?.stringValue } ?? []
        #expect(answered == ["tool_result", "tool_result", "text"])
        #expect(sent[4]["content"]?.arrayValue?.first?["tool_use_id"]?.stringValue == "t3")
    }

    @Test func openAIWireFormAnswersEveryCall() {
        let broken: [AgentMessage] = [
            .user("hi"),
            turn(.assistant, [.text("checking"), call("t1"), call("t2")]),
            .user("carry on"),
            turn(.assistant, [call("t3")]),
        ]
        let sent = OpenAICompatibleProvider.messagesJSON(broken)
        #expect(openAIPairingIsValid(sent), "each tool_call id gets a tool message immediately after")
        #expect(sent.map { $0["role"]?.stringValue } == [
            "user", "assistant", "tool", "tool", "user", "assistant", "tool",
        ])
    }

    // MARK: AgentSession

    @Test func cutOffReplyWithAToolCallLeavesAValidTranscript() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let cutOff = LLMResponse(
            message: turn(.assistant, [.text("Let me look."), call("t1")]),
            stopReason: .maxTokens,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [cutOff, FakeProvider.reply("still here")])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("check the disk")
        await waitUntilDone(session)

        #expect(toolPairingIsValid(session.messages))
        #expect(session.messages.last?.blocks == [interruptedByLimit("t1")])
        #expect(session.lastError?.contains("output limit") == true)
        #expect(host.executed.isEmpty, "a truncated call must not run")

        session.send("continue")
        await waitUntilDone(session)
        #expect(toolPairingIsValid(session.messages))
        #expect(toolPairingIsValid(provider.requests.last?.messages ?? []), "the next request is valid")
    }

    @Test func droppedConnectionWithAToolCallLeavesAValidTranscript() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let dropped = LLMResponse(
            message: turn(.assistant, [.text("Checking"), call("t1")]),
            stopReason: .other,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [dropped, FakeProvider.reply("ok")])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)
        #expect(toolPairingIsValid(session.messages))
        #expect(session.messages.last?.blocks == [interrupted("t1")])
        #expect(session.lastError == "The reply was interrupted before a tool call finished. Send \"continue\" to go on.")

        session.send("go on")
        await waitUntilDone(session)
        #expect(toolPairingIsValid(session.messages))
        #expect(toolPairingIsValid(provider.requests.last?.messages ?? []))
    }

    @Test func endTurnWithACallExplainsTheInterruption() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let reply = LLMResponse(
            message: turn(.assistant, [call("t1")]),
            stopReason: .endTurn,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [reply])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)
        #expect(toolPairingIsValid(session.messages))
        #expect(session.messages.last?.blocks == [interrupted("t1")])
        #expect(session.lastError == "The reply was interrupted before a tool call finished. Send \"continue\" to go on.")
        #expect(host.executed.isEmpty)
    }

    @Test func truncatedCallInputIsAnsweredButNotRun() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let truncated = LLMResponse(
            message: turn(.assistant, [
                .toolUse(id: "t1", name: "run_command", input: ToolCallInput.decoded("{\"host\":\"web-01\",\"comm")),
                .toolUse(id: "t2", name: "run_command", input: ["host": "web-01", "command": "uptime", "reason": "load"]),
            ]),
            stopReason: .toolUse,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [truncated, FakeProvider.reply("done")])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)

        #expect(host.executed.map(\.command) == ["uptime"], "the complete call still runs, in order")
        let results = session.messages[2].blocks
        #expect(results.first == .toolResult(toolUseID: "t1", content: AgentTranscript.cutOffInputToolCallText, isError: true))
        guard results.count == 2, case .toolResult(let id, let content, let isError) = results[1] else {
            Issue.record("the second call is answered")
            return
        }
        #expect(id == "t2")
        #expect(!isError)
        #expect(content.contains("ran: uptime"))
        #expect(toolPairingIsValid(session.messages))
    }

    @Test func repeatedCallIDRunsOnlyTheFirst() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let repeated = LLMResponse(
            message: turn(.assistant, [
                .toolUse(id: "t1", name: "run_command", input: ["host": "web-01", "command": "uptime", "reason": "load"]),
                .toolUse(id: "t1", name: "run_command", input: ["host": "web-01", "command": "df -h", "reason": "disk"]),
            ]),
            stopReason: .toolUse,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [repeated, FakeProvider.reply("done")])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)

        #expect(host.executed.map(\.command) == ["uptime"])
        #expect(session.messages[1].toolUses.map(\.id) == ["t1"])
        #expect(session.messages[2].blocks.count == 1)
        #expect(toolPairingIsValid(session.messages))
    }

    @Test func cutOffInputIsStoredShort() async {
        let host = FakeToolHost(hosts: [])
        let long = String(repeating: "x", count: 5_000)
        let reply = LLMResponse(
            message: turn(.assistant, [
                .toolUse(id: "t1", name: "run_command", input: ToolCallInput.decoded(long)),
            ]),
            stopReason: .other,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [reply])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)

        guard case .toolUse(_, _, let input)? = session.messages[1].blocks.first else {
            Issue.record("the call is kept")
            return
        }
        #expect(ToolCallInput.rawArguments(in: input)?.count == 2_000, "the partial input is bounded")
        #expect(toolPairingIsValid(session.messages))
    }

    @Test func replyWithNoReadableContentIsNotAppended() async {
        let host = FakeToolHost(hosts: [])
        let reply = LLMResponse(
            message: turn(.assistant, [.toolUse(id: "", name: "run_command", input: [:])]),
            stopReason: .toolUse,
            model: "fake-model",
            usage: LLMUsage()
        )
        let provider = FakeProvider(responses: [reply])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)

        #expect(session.messages.count == 1, "no empty assistant turn is appended")
        #expect(session.lastError == "The model's reply could not be read. Send the message again.")
        #expect(toolPairingIsValid(session.messages))
        #expect(host.executed.isEmpty)
    }

    @Test func aNewRunWaitsForTheAbandonedToolCall() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let gate = Gate()
        let toolStarted = Signal()
        host.approval = { _ in
            await toolStarted.set()
            await gate.wait()
            return .approved
        }
        let provider = FakeProvider(responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "uptime", "reason": "load"]),
            FakeProvider.reply("new reply"),
        ])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("old question")
        for _ in 0..<400 {
            if await toolStarted.isSet { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let started = await toolStarted.isSet
        #expect(started)
        #expect(provider.requests.count == 1)

        session.replace(messages: [.user("new question")])
        session.send("follow up")
        #expect(session.isRunning)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.requests.count == 1, "the new run waits for the abandoned tool call")

        await gate.open()
        await waitUntilDone(session)
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.messages.map(\.text) == ["new question", "follow up"])
        #expect(session.messages.map(\.text) == ["new question", "follow up", "new reply"])
    }

    @Test func droppedOpenAIStreamDoesNotRunTheCall() async throws {
        var assembler = OpenAIStreamAssembler(model: "llama")
        for data in [
            #"{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run_command","arguments":"{\"host\":\"web-01\",\"command\":\"uptime\","}}]},"finish_reason":null}]}"#,
        ] {
            _ = try assembler.handle(SSEParser.Event(name: nil, data: data))
        }
        guard let dropped = assembler.finishIfNeeded() else {
            Issue.record("no response for a dropped stream")
            return
        }
        #expect(dropped.stopReason == .other)

        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let provider = FakeProvider(responses: [dropped])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("go")
        await waitUntilDone(session)
        #expect(host.executed.isEmpty, "a dropped stream must not run the call")
        #expect(toolPairingIsValid(session.messages))
        #expect(session.lastError == "The reply was interrupted before a tool call finished. Send \"continue\" to go on.")
    }

    @Test func decodedTranscriptWithAnUnansweredCallHealsOnReplaceAndSend() async throws {
        let stored = try AgentTranscript.encode([.user("hi"), turn(.assistant, [call("t1")])])
        let decoded = try AgentTranscript.decode(stored)
        #expect(!toolPairingIsValid(decoded), "the fixture is what older versions saved")

        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let provider = FakeProvider(responses: [FakeProvider.reply("fixed")])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))
        var saved: [AgentMessage] = []
        session.transcriptDidChange = { saved = session.messages }

        session.replace(messages: decoded)
        #expect(toolPairingIsValid(session.messages))
        #expect(session.messages.last?.blocks == [lost("t1")])

        session.send("carry on")
        await waitUntilDone(session)
        #expect(toolPairingIsValid(session.messages))
        #expect(toolPairingIsValid(provider.requests.first?.messages ?? []))
        #expect(toolPairingIsValid(saved), "the healed transcript is saved")
    }

    @Test func initHealsABrokenTranscript() {
        let host = FakeToolHost(hosts: [])
        let session = AgentSession(
            provider: FakeProvider(responses: []),
            systemPrompt: "sys",
            toolRunner: AgentToolRunner(host: host, source: .agentPanel),
            messages: [.user("hi"), turn(.assistant, [call("t1")])]
        )
        #expect(toolPairingIsValid(session.messages))
        #expect(session.messages.last?.blocks == [lost("t1")])
    }

    @Test func rewindLeavesAValidTranscriptAndNotifies() {
        let host = FakeToolHost(hosts: [])
        let session = AgentSession(
            provider: FakeProvider(responses: []),
            systemPrompt: "sys",
            toolRunner: AgentToolRunner(host: host, source: .agentPanel),
            messages: [
                .user("hi"),
                turn(.assistant, [call("t1")]),
                turn(.user, [answer("t1")]),
                turn(.assistant, [.text("done")]),
            ]
        )
        #expect(toolPairingIsValid(session.messages))
        var saves = 0
        session.transcriptDidChange = { saves += 1 }

        // Cutting at the results turn leaves the call unanswered at the end.
        _ = session.rewind(to: session.messages[2].id)
        #expect(toolPairingIsValid(session.messages))
        #expect(session.messages.last?.blocks == [lost("t1")])
        #expect(saves == 1)
    }

    @Test func replaceDuringAStreamedReplyAbandonsTheOldRun() async {
        let host = FakeToolHost(hosts: [])
        let gate = Gate()
        let streamEnded = Signal()
        let provider = FakeProvider(responses: [FakeProvider.reply("old reply"), FakeProvider.reply("new reply")])
        provider.holdBeforeDone = { await gate.wait() }
        provider.afterStream = { await streamEnded.set() }
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("old question")
        for _ in 0..<400 where session.streamingText.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!session.streamingText.isEmpty)

        var saves = 0
        session.transcriptDidChange = { saves += 1 }
        let replacement: [AgentMessage] = [.user("new question"), turn(.assistant, [.text("old answer")])]
        session.replace(messages: replacement)
        #expect(!session.isRunning)
        #expect(session.messages == AgentTranscript.repaired(replacement))
        #expect(saves == 0)

        await gate.open()
        for _ in 0..<400 {
            if await streamEnded.isSet { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let ended = await streamEnded.isSet
        #expect(ended)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.messages == AgentTranscript.repaired(replacement), "the abandoned run appended nothing")
        #expect(session.messages.count == 2)
        #expect(saves == 0, "the abandoned run did not save its partial reply")
        #expect(session.streamingText.isEmpty)

        session.send("follow up")
        await waitUntilDone(session)
        #expect(provider.requests.last?.messages.map(\.text) == ["new question", "old answer", "follow up"])
        #expect(session.messages.map(\.text) == ["new question", "old answer", "follow up", "new reply"])
        #expect(toolPairingIsValid(session.messages))
    }

    @Test func replaceDuringAToolCallAbandonsTheOldRun() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let approvalExited = Signal()
        host.approval = { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await approvalExited.set()
            return .denied
        }
        let provider = FakeProvider(responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "uptime", "reason": "load"]),
            FakeProvider.reply("new reply"),
        ])
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: AgentToolRunner(host: host, source: .agentPanel))

        session.send("old question")
        for _ in 0..<400 where host.approvalRequests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(host.approvalRequests.count == 1)

        var saves = 0
        session.transcriptDidChange = { saves += 1 }
        let replacement: [AgentMessage] = [.user("new question")]
        session.replace(messages: replacement)
        #expect(!session.isRunning)
        #expect(session.messages == AgentTranscript.repaired(replacement))
        #expect(saves == 0)

        for _ in 0..<400 {
            if await approvalExited.isSet { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let exited = await approvalExited.isSet
        #expect(exited)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.messages == AgentTranscript.repaired(replacement), "the abandoned run appended no results")
        #expect(session.messages.count == 1)
        #expect(saves == 0, "the abandoned run did not save")
        #expect(host.executed.isEmpty)

        session.send("follow up")
        await waitUntilDone(session)
        #expect(provider.requests.last?.messages.map(\.text) == ["new question", "follow up"])
        #expect(session.messages.map(\.text) == ["new question", "follow up", "new reply"])
        #expect(toolPairingIsValid(session.messages))
    }

    private func waitUntilDone(_ session: AgentSession) async {
        for _ in 0..<400 where session.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.isRunning)
    }
}
