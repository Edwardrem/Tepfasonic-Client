import SwiftUI
import TepfaAgent
import TepfaCore

/// "Claude wants to run…" with the exact command, the host and the reason.
/// Approve runs it as shown, editing runs the edited text, Deny tells the model no.
struct AgentApprovalSheet: View {
    let prompt: AgentApprovalPrompt
    @State private var command: String

    init(prompt: AgentApprovalPrompt) {
        self.prompt = prompt
        _command = State(initialValue: prompt.request.command)
    }

    private var request: AgentApprovalRequest { prompt.request }
    private var isEdited: Bool { command != request.command }
    private var isEmpty: Bool { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: request.isDestructive ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.title)
                    .foregroundStyle(request.isDestructive ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.isDestructive ? "Claude wants to run a destructive command" : "Claude wants to run a command")
                        .font(.headline)
                    Text(request.source == .mcp ? "Requested by an MCP client (Claude Desktop or Claude Code)" : "Requested from the Claude panel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Host").foregroundStyle(.secondary)
                    Text("\(request.host.name)  ·  \(request.host.target)").textSelection(.enabled)
                }
                GridRow {
                    Text("Tool").foregroundStyle(.secondary)
                    Text(request.tool).font(.body.monospaced())
                }
                GridRow {
                    Text("Reason").foregroundStyle(.secondary)
                    Text(request.reason.isEmpty ? "(none given)" : request.reason).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Command").foregroundStyle(.secondary)
                TextEditor(text: $command)
                    .font(.body.monospaced())
                    .frame(minHeight: 64, maxHeight: 160)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(request.isDestructive ? Color.red.opacity(0.6) : Color(nsColor: .separatorColor)))
                Text(request.detail)
                    .font(.caption)
                    .foregroundStyle(request.isDestructive ? .red : .secondary)
            }
            HStack {
                Button("Deny") { prompt.resume(.denied) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isEdited {
                    Button("Run Edited Command") { prompt.resume(.edited(command)) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isEmpty)
                } else {
                    Button("Approve") { prompt.resume(.approved) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}
