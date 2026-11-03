import Foundation
import TepfaCore
@testable import TepfaAgent

/// A scripted model: each call streams the next response.
final class FakeProvider: LLMProvider, @unchecked Sendable {
    var responses: [LLMResponse]
    private(set) var requests: [LLMRequest] = []
    var delayBetweenDeltas: Duration = .zero

    init(responses: [LLMResponse]) {
        self.responses = responses
    }

    var displayName: String { "fake" }
    var modelName: String { "fake-model" }

    static func reply(_ text: String, stop: LLMStopReason = .endTurn) -> LLMResponse {
        LLMResponse(message: AgentMessage(role: .assistant, blocks: [.text(text)]), stopReason: stop, model: "fake-model", usage: LLMUsage(inputTokens: 10, outputTokens: 5))
    }

    static func toolCall(_ name: AgentToolName, id: String = "t1", _ input: JSONValue, text: String = "") -> LLMResponse {
        var blocks: [AgentContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(.toolUse(id: id, name: name.rawValue, input: input))
        return LLMResponse(message: AgentMessage(role: .assistant, blocks: blocks), stopReason: .toolUse, model: "fake-model", usage: LLMUsage(inputTokens: 10, outputTokens: 5))
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        requests.append(request)
        let response = responses.isEmpty ? Self.reply("(no scripted reply)") : responses.removeFirst()
        let delay = delayBetweenDeltas
        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.started(model: response.model))
                for block in response.message.blocks {
                    if case .text(let text) = block {
                        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                            if delay > .zero { try? await Task.sleep(for: delay) }
                            continuation.yield(.textDelta(String(word) + " "))
                        }
                    }
                }
                continuation.yield(.done(response))
                continuation.finish()
            }
        }
    }
}

/// Records what the tools asked for; answers approvals and commands with closures.
@MainActor
final class FakeToolHost: AgentToolHost {
    var hostList: [AgentHostInfo]
    var approval: (AgentApprovalRequest) async -> AgentApprovalResponse = { _ in .approved }
    var executor: (AgentHostInfo, String, Data) async throws -> AgentCommandOutput = { _, command, _ in
        AgentCommandOutput(stdout: Data("ran: \(command)\n".utf8), stderr: Data(), exitStatus: 0, duration: .milliseconds(5))
    }
    var buffers: [UUID: String] = [:]
    private(set) var approvalRequests: [AgentApprovalRequest] = []
    private(set) var executed: [(host: String, command: String, stdin: Data, echo: AgentEchoMode)] = []
    private(set) var auditRecords: [AgentAuditRecord] = []

    init(hosts: [AgentHostInfo]) {
        hostList = hosts
    }

    static let web = AgentHostInfo(id: UUID(), name: "web-01", hostname: "10.0.0.5", username: "ubuntu", group: "Prod", tags: ["nginx"], permission: .ask)
    static let db = AgentHostInfo(id: UUID(), name: "db-01", hostname: "10.0.0.6", username: "postgres", permission: .readOnly)
    static let lab = AgentHostInfo(id: UUID(), name: "lab", hostname: "lab.local", port: 2222, username: "me", permission: .allowlist, allowlist: ["df *", "systemctl restart *", "write_file /srv/app/*"])

    func hosts() -> [AgentHostInfo] { hostList }

    func approve(_ request: AgentApprovalRequest) async -> AgentApprovalResponse {
        approvalRequests.append(request)
        return await approval(request)
    }

    func execute(on host: AgentHostInfo, command: String, stdin: Data, timeout: Duration, echo: AgentEchoMode, source: AgentActionSource) async throws -> AgentCommandOutput {
        executed.append((host.name, command, stdin, echo))
        return try await executor(host, command, stdin)
    }

    func terminalBuffer(on host: AgentHostInfo, maxLines: Int) -> String? {
        buffers[host.id]
    }

    func audit(_ record: AgentAuditRecord) {
        auditRecords.append(record)
    }
}
