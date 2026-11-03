import Foundation
import Observation
import SwiftData
import TepfaAgent
import TepfaCore
import TepfaTerminal

/// Owns the live `AgentSession`, the conversation it is saved to, and the
/// scope (one host, a group, or everything) the conversation is about.
@MainActor
@Observable
final class AgentPanelController {
    enum Scope: Hashable {
        case all
        case host(UUID)
        case group(UUID)
    }

    private let toolHost: AppAgentHost
    private let context: ModelContext
    private let workspace: Workspace
    private let settings: AgentSettings

    private(set) var scope: Scope = .all
    private(set) var session: AgentSession?
    private(set) var conversation: AgentConversation?
    /// Why the last send could not start (missing key, bad URL).
    private(set) var setupError: String?
    /// Bumped whenever the saved conversation list changes.
    private(set) var conversationsVersion = 0
    private var providerConfiguration: LLMProviderConfiguration?

    init(toolHost: AppAgentHost, context: ModelContext, workspace: Workspace, settings: AgentSettings = .shared) {
        self.toolHost = toolHost
        self.context = context
        self.workspace = workspace
        self.settings = settings
    }

    // MARK: Scope

    var hosts: [SSHHost] {
        (try? context.fetch(FetchDescriptor<SSHHost>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    var groups: [HostGroup] {
        (try? context.fetch(FetchDescriptor<HostGroup>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    var scopeTitle: String {
        switch scope {
        case .all: "All hosts"
        case .host(let id): hosts.first { $0.uuid == id }?.name ?? "Host"
        case .group(let id): groups.first { $0.uuid == id }?.name ?? "Group"
        }
    }

    /// Changes the scope and opens its most recent conversation.
    func focus(_ scope: Scope) {
        guard scope != self.scope || session == nil else { return }
        stop()
        self.scope = scope
        if let latest = conversations().first {
            open(latest)
        } else {
            newConversation()
        }
    }

    /// Points the panel at the focused terminal's host when it has one and nothing was chosen yet.
    func focusOnWorkspaceIfIdle() {
        guard session == nil, let host = workspace.focusedSession?.host, !host.isTransient else { return }
        focus(.host(host.id))
    }

    // MARK: Conversations

    func conversations() -> [AgentConversation] {
        let all = (try? context.fetch(FetchDescriptor<AgentConversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return all.filter { stored in
            switch scope {
            case .all: stored.hostID == nil && stored.groupID == nil
            case .host(let id): stored.hostID == id
            case .group(let id): stored.groupID == id
            }
        }
    }

    func open(_ stored: AgentConversation) {
        stop()
        conversation = stored
        let messages = (try? AgentTranscript.decode(stored.transcript)) ?? []
        if let session {
            session.replace(messages: messages)
        } else {
            session = makeSession(messages: messages)
        }
        setupError = nil
    }

    func newConversation() {
        stop()
        conversation = nil
        if let session {
            session.replace(messages: [])
        } else {
            session = makeSession(messages: [])
        }
        setupError = nil
    }

    func delete(_ stored: AgentConversation) {
        if stored === conversation { newConversation() }
        context.delete(stored)
        try? context.save()
        conversationsVersion += 1
    }

    // MARK: Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = session ?? makeSession(messages: [])
        self.session = session
        guard session.canSend else { return }
        setupError = nil
        Task {
            do {
                if providerConfiguration != settings.configuration || session.provider is PlaceholderProvider {
                    session.provider = try await settings.makeProvider()
                    providerConfiguration = settings.configuration
                }
                session.systemPrompt = systemPrompt()
                session.send(trimmed)
            } catch {
                setupError = error.localizedDescription
            }
        }
    }

    func stop() {
        session?.stop()
    }

    private func makeSession(messages: [AgentMessage]) -> AgentSession {
        let runner = AgentToolRunner(host: toolHost, source: .agentPanel, conversationID: conversation?.uuid)
        let session = AgentSession(provider: PlaceholderProvider(), systemPrompt: systemPrompt(), toolRunner: runner, messages: messages)
        session.transcriptDidChange = { [weak self] in self?.persist() }
        return session
    }

    private func systemPrompt() -> String {
        let infos = toolHost.hosts()
        switch scope {
        case .all:
            return AgentSystemPrompt.build(hosts: infos, focus: nil)
        case .host(let id):
            return AgentSystemPrompt.build(hosts: infos, focus: infos.first { $0.id == id })
        case .group(let id):
            let group = groups.first { $0.uuid == id }
            let members = Set(group?.hosts.map(\.uuid) ?? [])
            return AgentSystemPrompt.build(hosts: infos.filter { members.contains($0.id) }, focus: nil, groupName: group?.name)
        }
    }

    private func persist() {
        guard let session else { return }
        let messages = session.messages
        if messages.isEmpty {
            return
        }
        let stored: AgentConversation
        if let conversation {
            stored = conversation
        } else {
            let firstLine = messages.first { $0.role == .user }?.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Conversation"
            let title = firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : firstLine
            var hostID: UUID?
            var groupID: UUID?
            if case .host(let id) = scope { hostID = id }
            if case .group(let id) = scope { groupID = id }
            stored = AgentConversation(title: title, hostID: hostID, groupID: groupID)
            context.insert(stored)
            conversation = stored
            session.toolRunner.conversationID = stored.uuid
            conversationsVersion += 1
        }
        stored.transcript = (try? AgentTranscript.encode(messages)) ?? Data()
        stored.updatedAt = .now
        if let model = session.lastModel { stored.model = model }
        try? context.save()
    }
}

/// Stands in until the real provider is built from settings on the first send.
private struct PlaceholderProvider: LLMProvider {
    var displayName: String { "none" }
    var modelName: String { "" }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentSetupError(message: "No model is configured.")) }
    }
}
