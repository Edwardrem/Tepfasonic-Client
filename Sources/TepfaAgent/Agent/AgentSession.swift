import Foundation
import Observation
import TepfaCore

/// One conversation with the model: streams replies, runs tool calls through
/// the guarded runner, and keeps the transcript.
@MainActor
@Observable
public final class AgentSession {
    public private(set) var messages: [AgentMessage]
    public private(set) var isRunning = false
    /// Text of the reply being streamed right now.
    public private(set) var streamingText = ""
    public private(set) var streamingThinking = ""
    /// Tool call in progress, for the status line.
    public private(set) var activeTool: String?
    public private(set) var lastError: String?
    public private(set) var lastModel: String?
    public private(set) var servedByFallback = false
    public private(set) var usage = LLMUsage()

    public var provider: any LLMProvider
    public var systemPrompt: String
    public let toolRunner: AgentToolRunner
    public var tools: [AgentToolDefinition] = AgentTools.all
    /// Rounds of tool calls per user message before the agent stops to check in.
    public var maxToolRounds = 40
    /// Called whenever the transcript changes, for persistence.
    public var transcriptDidChange: (() -> Void)?

    private var task: Task<Void, Never>?
    /// A run that `replace` abandoned; the next `start` waits for it to unwind
    /// so two runs never use the same tool runner at once.
    private var abandonedTask: Task<Void, Never>?
    /// Identifies the current run, so a run abandoned by `replace` can tell and
    /// stop touching the session. Bumped by `start` and by `replace`.
    private var runGeneration = 0
    /// Keep at most this much unparsed input from a call that never completed.
    private static let maximumStoredCutOffInputLength = 2_000

    public init(provider: any LLMProvider, systemPrompt: String, toolRunner: AgentToolRunner, messages: [AgentMessage] = []) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.toolRunner = toolRunner
        self.messages = AgentTranscript.repaired(messages)
    }

    public var canSend: Bool { !isRunning }

    public func send(_ text: String, attachments: [AgentAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isRunning else { return }
        // A transcript loaded from an older version can end in an unanswered call;
        // heal it before the new turn goes after it.
        messages = AgentTranscript.repaired(messages)
        append(.user(trimmed, attachments: attachments))
        start()
    }

    /// Stops the current reply or tool call. Pending tool calls get error results so the transcript stays valid.
    public func stop() {
        task?.cancel()
    }

    public func clear() {
        guard !isRunning else { return }
        messages = []
        lastError = nil
        transcriptDidChange?()
    }

    /// Replaces the whole conversation. A reply in flight belongs to the old
    /// conversation, so it is abandoned rather than allowed to save its partial
    /// turn into the new one; the swap always takes effect.
    public func replace(messages: [AgentMessage]) {
        if isRunning {
            if let running = task {
                running.cancel()
                abandonedTask = running
            }
            runGeneration += 1
            isRunning = false
            streamingText = ""
            streamingThinking = ""
            activeTool = nil
            task = nil
        }
        self.messages = AgentTranscript.repaired(messages)
        lastError = nil
    }

    /// Drops the message with this id and everything after it, so an earlier
    /// user message can be edited and sent again. Returns the dropped message,
    /// or nil when a reply is running or the id is unknown.
    @discardableResult
    public func rewind(to messageID: UUID) -> AgentMessage? {
        guard !isRunning, let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let message = messages[index]
        messages.removeSubrange(index...)
        // Cutting at any id can leave a reply with unanswered calls at the end.
        messages = AgentTranscript.repaired(messages)
        lastError = nil
        transcriptDidChange?()
        return message
    }

    private func start() {
        lastError = nil
        isRunning = true
        runGeneration += 1
        let generation = runGeneration
        let previous = abandonedTask
        abandonedTask = nil
        task = Task { [weak self] in
            // A run abandoned by replace must finish unwinding before the next
            // one starts, or two tool calls could overlap on the same runner.
            _ = await previous?.value
            await self?.run(generation: generation)
            self?.finishRun(generation: generation)
        }
    }

    private func finishRun(generation: Int) {
        guard isCurrent(generation) else { return }
        isRunning = false
        streamingText = ""
        streamingThinking = ""
        activeTool = nil
        task = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        runGeneration == generation
    }

    private func append(_ message: AgentMessage) {
        messages.append(message)
        transcriptDidChange?()
    }

    private func run(generation: Int) async {
        for _ in 0..<maxToolRounds {
            guard isCurrent(generation) else { return }
            streamingText = ""
            streamingThinking = ""
            activeTool = nil
            let response: LLMResponse
            do {
                response = try await streamOnce(generation: generation)
            } catch is CancellationError {
                guard isCurrent(generation) else { return }
                if !streamingText.isEmpty { append(AgentMessage(role: .assistant, blocks: [.text(streamingText)], model: lastModel)) }
                lastError = "Stopped."
                return
            } catch {
                guard isCurrent(generation) else { return }
                if Task.isCancelled {
                    lastError = "Stopped."
                } else {
                    lastError = error.localizedDescription
                }
                return
            }
            guard isCurrent(generation) else { return }
            // Keep the stored partial input small and drop calls this turn cannot
            // keep (an empty id or a repeated one) before the reply is saved.
            let normalised = AgentTranscript.withoutInvalidToolUses(response.message)
            // A reply whose only content was unusable calls has nothing to show.
            guard !normalised.blocks.isEmpty || response.message.blocks.isEmpty else {
                lastError = "The model's reply could not be read. Send the message again."
                return
            }
            let reply = Self.boundingCutOffInputs(normalised)
            append(reply)
            lastModel = response.model
            servedByFallback = response.servedByFallback
            usage.inputTokens += response.usage.inputTokens
            usage.outputTokens += response.usage.outputTokens
            usage.cacheReadTokens += response.usage.cacheReadTokens
            usage.cacheWriteTokens += response.usage.cacheWriteTokens

            // A reply that carries calls but did not stop for tools (cut off,
            // refused, connection dropped) must answer them immediately, or the
            // API rejects every later message in the conversation.
            let interruptedCalls = response.stopReason == .toolUse ? [] : reply.toolUses
            if !interruptedCalls.isEmpty {
                let text = response.stopReason == .maxTokens
                    ? AgentTranscript.maxTokensToolCallText
                    : AgentTranscript.interruptedToolCallText
                append(AgentMessage(role: .user, blocks: interruptedCalls.map {
                    .toolResult(toolUseID: $0.id, content: text, isError: true)
                }))
            }

            switch response.stopReason {
            case .toolUse:
                // A call whose streamed input did not parse is truncated JSON and
                // must not run; complete calls in the same reply still run, in order.
                let uses = reply.toolUses
                guard !uses.isEmpty else { return }
                var results: [AgentContentBlock] = []
                for use in uses {
                    if Task.isCancelled {
                        results.append(.toolResult(toolUseID: use.id, content: "Cancelled by the user before it ran.", isError: true))
                        continue
                    }
                    guard ToolCallInput.rawArguments(in: use.input) == nil else {
                        results.append(.toolResult(toolUseID: use.id, content: AgentTranscript.cutOffInputToolCallText, isError: true))
                        continue
                    }
                    activeTool = use.name
                    let result = await toolRunner.call(name: use.name, input: use.input)
                    guard isCurrent(generation) else { return }
                    results.append(.toolResult(toolUseID: use.id, content: result.content, isError: result.isError))
                }
                activeTool = nil
                append(AgentMessage(role: .user, blocks: results))
                if Task.isCancelled {
                    lastError = "Stopped."
                    return
                }
            case .pauseTurn:
                continue
            case .maxTokens:
                lastError = "The reply was cut off at the model's output limit. Send \"continue\" to go on."
                return
            case .refusal:
                lastError = "The model declined to continue" + (response.refusalCategory.map { " (\($0))" } ?? "") + "."
                return
            case .endTurn, .other:
                if !interruptedCalls.isEmpty {
                    lastError = "The reply was interrupted before a tool call finished. Send \"continue\" to go on."
                }
                return
            }
        }
        guard isCurrent(generation) else { return }
        lastError = "Stopped after \(maxToolRounds) rounds of tool calls. Send a message to continue."
    }

    private func streamOnce(generation: Int) async throws -> LLMResponse {
        // Defence in depth: the provider gets a transcript the API accepts even
        // if some other path left an unanswered call behind.
        let request = LLMRequest(system: systemPrompt, messages: AgentTranscript.repaired(messages), tools: tools)
        var final: LLMResponse?
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            guard isCurrent(generation) else { throw CancellationError() }
            switch event {
            case .started(let model): lastModel = model
            case .textDelta(let piece): streamingText += piece
            case .thinkingDelta(let piece): streamingThinking += piece
            case .toolUseStarted(let name): activeTool = name
            case .done(let response): final = response
            }
        }
        guard isCurrent(generation) else { throw CancellationError() }
        guard let final else { throw LLMError.invalidResponse("the stream ended without a message") }
        return final
    }

    /// Keeps a large unparsed input short: it is saved and sent again with every
    /// later request, so only its start is useful to show that the call failed.
    private static func boundingCutOffInputs(_ message: AgentMessage) -> AgentMessage {
        var message = message
        message.blocks = message.blocks.map { block in
            guard case .toolUse(let id, let name, let input) = block,
                  let partial = ToolCallInput.rawArguments(in: input) else { return block }
            let bounded = String(partial.prefix(maximumStoredCutOffInputLength))
            return .toolUse(id: id, name: name, input: .object([ToolCallInput.rawArgumentsKey: .string(bounded)]))
        }
        return message
    }
}
