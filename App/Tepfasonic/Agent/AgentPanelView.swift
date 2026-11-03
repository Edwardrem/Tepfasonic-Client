import SwiftUI
import TepfaAgent
import TepfaCore
import TepfaTerminal

/// The Claude panel: scope and conversation pickers, the transcript, and the composer.
struct AgentPanelView: View {
    @Environment(AgentPanelController.self) private var controller
    @Environment(AppState.self) private var appState
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session = controller.session {
                AgentTranscriptView(session: session)
            } else {
                ContentUnavailableView {
                    Label("Ask Claude", systemImage: "sparkles")
                } description: {
                    Text("Claude can inspect and operate your hosts with the tools list_hosts, run_command, read_file, write_file, sftp_transfer and read_terminal_buffer. Every command is shown in an agent tab, and the host's permission mode decides what asks first.")
                }
            }
            Divider()
            statusLine
            composer
        }
        .frame(minWidth: 320)
        .onAppear {
            controller.focusOnWorkspaceIfIdle()
            composerFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All hosts") { controller.focus(.all) }
                if !controller.groups.isEmpty {
                    Section("Groups") {
                        ForEach(controller.groups) { group in
                            Button(group.name) { controller.focus(.group(group.uuid)) }
                        }
                    }
                }
                Section("Hosts") {
                    ForEach(controller.hosts) { host in
                        Button(host.name) { controller.focus(.host(host.uuid)) }
                    }
                }
            } label: {
                Label(controller.scopeTitle, systemImage: scopeIcon)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which hosts this conversation is about")
            Spacer()
            Menu {
                Button("New Conversation") { controller.newConversation() }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                let conversations = controller.conversations()
                if !conversations.isEmpty {
                    Section("Saved for \(controller.scopeTitle)") {
                        ForEach(conversations) { stored in
                            Button {
                                controller.open(stored)
                            } label: {
                                if stored === controller.conversation {
                                    Label(stored.title, systemImage: "checkmark")
                                } else {
                                    Text(stored.title)
                                }
                            }
                        }
                    }
                }
                if let current = controller.conversation {
                    Divider()
                    Button("Delete This Conversation", role: .destructive) { controller.delete(current) }
                }
            } label: {
                Label(controller.conversation?.title ?? "New conversation", systemImage: "bubble.left.and.text.bubble.right")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .trailing)
            .id(controller.conversationsVersion)
            .help("Saved conversations")
            Button {
                appState.isShowingAgentPanel = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide the Claude panel (⌘⇧A)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var scopeIcon: String {
        switch controller.scope {
        case .all: "server.rack"
        case .host: "desktopcomputer"
        case .group: "folder"
        }
    }

    // MARK: Status and composer

    @ViewBuilder
    private var statusLine: some View {
        let session = controller.session
        HStack(spacing: 8) {
            if let error = controller.setupError ?? session?.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(2).textSelection(.enabled)
            } else if let session, session.isRunning {
                ProgressView().controlSize(.small)
                Text(session.activeTool.map { "Running \($0)…" } ?? (session.streamingThinking.isEmpty ? "Thinking…" : "Reasoning…"))
            } else if let session, let model = session.lastModel {
                Text(model)
                if session.servedByFallback {
                    Text("fallback").padding(.horizontal, 5).background(.orange.opacity(0.25), in: Capsule())
                }
                if session.usage.inputTokens + session.usage.outputTokens > 0 {
                    Text("\(session.usage.inputTokens.formatted()) in · \(session.usage.outputTokens.formatted()) out")
                }
            } else {
                Text(AgentSettings.shared.configuration.model)
            }
            Spacer()
            if let session, session.isRunning {
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask Claude about \(controller.scopeTitle)…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(send)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.session?.isRunning == true)
            .help("Send (⌘↩)")
        }
        .padding(10)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, controller.session?.isRunning != true else { return }
        draft = ""
        controller.send(text)
    }
}

// MARK: - Transcript

struct AgentTranscriptView: View {
    let session: AgentSession

    private var toolResults: [String: (content: String, isError: Bool)] {
        var results: [String: (String, Bool)] = [:]
        for message in session.messages {
            for block in message.blocks {
                if case .toolResult(let id, let content, let isError) = block { results[id] = (content, isError) }
            }
        }
        return results
    }

    var body: some View {
        let results = toolResults
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.messages) { message in
                        AgentMessageView(message: message, results: results)
                    }
                    if session.isRunning {
                        AgentStreamingView(session: session)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: session.messages.count) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: session.streamingText.count) { _, _ in proxy.scrollTo("bottom") }
        }
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage
    let results: [String: (content: String, isError: Bool)]

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        MarkdownText(text)
                    case .thinking(let text, _):
                        ThinkingView(text: text)
                    case .redactedThinking:
                        Text("Thinking (redacted)").font(.caption).foregroundStyle(.tertiary)
                    case .toolUse(let id, let name, let input):
                        ToolCallView(name: name, input: input, result: results[id])
                    case .toolResult:
                        EmptyView()
                    }
                }
            }
        }
    }
}

private struct AgentStreamingView: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.streamingThinking.isEmpty {
                ThinkingView(text: session.streamingThinking, expanded: true)
            }
            if !session.streamingText.isEmpty {
                MarkdownText(session.streamingText)
            }
        }
    }
}

/// Inline Markdown (bold, code, links); falls back to plain text.
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }
}

private struct ThinkingView: View {
    let text: String
    var expanded = false
    @State private var isExpanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded ?? expanded }, set: { isExpanded = $0 })) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
        } label: {
            Label("Thinking", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A tool call with its result, collapsed to one line until clicked.
private struct ToolCallView: View {
    let name: String
    let input: JSONValue
    let result: (content: String, isError: Bool)?
    @State private var isExpanded = false

    private var summary: String {
        let host = input["host"]?.stringValue ?? ""
        switch AgentToolName(rawValue: name) {
        case .runCommand: return input["command"]?.stringValue ?? ""
        case .readFile: return "read \(input["path"]?.stringValue ?? "")"
        case .writeFile: return "write \(input["path"]?.stringValue ?? "")"
        case .sftpTransfer: return "\(input["direction"]?.stringValue ?? "transfer") \(input["remote_path"]?.stringValue ?? "")"
        case .readTerminalBuffer: return "terminal on \(host)"
        case .listHosts: return "list hosts"
        case nil: return name
        }
    }

    private var statusColor: Color {
        guard let result else { return .orange }
        if result.isError { return .red }
        if let status = exitStatus, status != 0 { return .yellow }
        return .green
    }

    private var exitStatus: Int? {
        guard let content = result?.content, let range = content.range(of: #"exit_status="(-?\d+)""#, options: .regularExpression) else { return nil }
        return Int(content[range].split(separator: "\"")[1])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let host = input["host"]?.stringValue, AgentToolName(rawValue: name) != .listHosts {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(summary).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let exitStatus { Text("exit \(exitStatus)").font(.caption2).foregroundStyle(.secondary) }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let reason = input["reason"]?.stringValue, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        Text(result?.content ?? "Waiting…")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
                .padding(.leading, 13)
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
