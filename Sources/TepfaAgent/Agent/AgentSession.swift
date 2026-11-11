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

    public init(provider: any LLMProvider, systemPrompt: String, toolRunner: AgentToolRunner, messages: [AgentMessage] = []) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.toolRunner = toolRunner
        self.messages = messages
    }

    public var canSend: Bool { !isRunning }

    public func send(_ text: String, attachments: [AgentAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isRunning else { return }
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

    public func replace(messages: [AgentMessage]) {
        guard !isRunning else { return }
        self.messages = messages
        lastError = nil
    }

    private func start() {
        lastError = nil
        isRunning = true
        task = Task { [weak self] in
            await self?.run()
            self?.finishRun()
        }
    }

    private func finishRun() {
        isRunning = false
        streamingText = ""
        streamingThinking = ""
        activeTool = nil
        task = nil
    }

    private func append(_ message: AgentMessage) {
        messages.append(message)
        transcriptDidChange?()
    }

    private func run() async {
        for _ in 0..<maxToolRounds {
            streamingText = ""
            streamingThinking = ""
            activeTool = nil
            let response: LLMResponse
            do {
                response = try await streamOnce()
            } catch is CancellationError {
                if !streamingText.isEmpty { append(AgentMessage(role: .assistant, blocks: [.text(streamingText)], model: lastModel)) }
                lastError = "Stopped."
                return
            } catch {
                if Task.isCancelled {
                    lastError = "Stopped."
                } else {
                    lastError = error.localizedDescription
                }
                return
            }
            append(response.message)
            lastModel = response.model
            servedByFallback = response.servedByFallback
            usage.inputTokens += response.usage.inputTokens
            usage.outputTokens += response.usage.outputTokens
            usage.cacheReadTokens += response.usage.cacheReadTokens
            usage.cacheWriteTokens += response.usage.cacheWriteTokens

            switch response.stopReason {
            case .toolUse:
                let uses = response.message.toolUses
                guard !uses.isEmpty else { return }
                var results: [AgentContentBlock] = []
                for use in uses {
                    if Task.isCancelled {
                        results.append(.toolResult(toolUseID: use.id, content: "Cancelled by the user before it ran.", isError: true))
                        continue
                    }
                    activeTool = use.name
                    let result = await toolRunner.call(name: use.name, input: use.input)
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
                return
            }
        }
        lastError = "Stopped after \(maxToolRounds) rounds of tool calls. Send a message to continue."
    }

    private func streamOnce() async throws -> LLMResponse {
        let request = LLMRequest(system: systemPrompt, messages: messages, tools: tools)
        var final: LLMResponse?
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .started(let model): lastModel = model
            case .textDelta(let piece): streamingText += piece
            case .thinkingDelta(let piece): streamingThinking += piece
            case .toolUseStarted(let name): activeTool = name
            case .done(let response): final = response
            }
        }
        guard let final else { throw LLMError.invalidResponse("the stream ended without a message") }
        return final
    }
}
