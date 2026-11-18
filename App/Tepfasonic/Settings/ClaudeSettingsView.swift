import AppKit
import SwiftData
import SwiftUI
import TepfaAgent
import TepfaCore

/// Model and API key for the panel, the MCP server, and the audit log.
struct ClaudeSettingsView: View {
    @Environment(MCPServerController.self) private var mcp
    @State private var settings = AgentSettings.shared
    @State private var apiKeyDraft = ""
    @State private var keyMessage: String?
    @State private var customModel = ""
    @State private var portText = ""
    @State private var caimexModels = [CaimexModel]()
    @State private var caimexLoading = false
    @State private var caimexError: String?
    @State private var caimexTypingCustom = false
    /// Each load gets a generation; only the latest may write the list, the error or the spinner.
    @State private var caimexLoadGeneration = 0

    private static let customModelTag = "custom"

    private var kind: LLMProviderConfiguration.Kind { settings.configuration.kind }

    private var configuration: Binding<LLMProviderConfiguration> {
        Binding(get: { settings.configuration }, set: { settings.configuration = $0 })
    }

    private var usesCustomModel: Bool {
        !LLMProviderConfiguration.anthropicModels.contains(settings.configuration.model)
    }

    private var caimexChoices: CaimexModelChoices {
        CaimexModelChoices(models: caimexModels, current: settings.configuration.model)
    }

    private var caimexModelBinding: Binding<String> {
        Binding(
            get: {
                if caimexTypingCustom { return Self.customModelTag }
                let model = settings.configuration.model
                return caimexChoices.ids.contains(model) ? model : Self.customModelTag
            },
            set: { choice in
                if choice == Self.customModelTag {
                    caimexTypingCustom = true
                } else {
                    caimexTypingCustom = false
                    settings.configuration.model = choice
                }
            }
        )
    }

    var body: some View {
        @Bindable var mcp = mcp
        Form {
            Section("Model") {
                Picker("Provider", selection: configuration.kind) {
                    ForEach(LLMProviderConfiguration.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                if settings.configuration.kind == .anthropic {
                    Picker("Model", selection: Binding(
                        get: { usesCustomModel ? "custom" : settings.configuration.model },
                        set: { choice in
                            if choice == "custom" {
                                customModel = settings.configuration.model
                                settings.configuration.model = customModel.isEmpty ? "custom-model" : customModel
                            } else {
                                settings.configuration.model = choice
                            }
                        })) {
                        ForEach(LLMProviderConfiguration.anthropicModels, id: \.self) { model in
                            Text(model + (model == LLMProviderConfiguration.defaultAnthropicModel ? " (default)" : "")).tag(model)
                        }
                        Text("Other…").tag("custom")
                    }
                    if usesCustomModel {
                        TextField("Model ID", text: configuration.model)
                            .font(.body.monospaced())
                    }
                    Picker("Effort", selection: Binding(get: { settings.configuration.effort ?? "" }, set: { settings.configuration.effort = $0.isEmpty ? nil : $0 })) {
                        Text("Model default").tag("")
                        ForEach(LLMProviderConfiguration.efforts, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Adaptive thinking is on; effort trades depth for speed and cost. Opus 5.5, Opus 5, Sonnet 5.5 and Fable 5.1 fall back to another Claude model on a safety refusal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.configuration.kind == .caimex {
                    caimexModelSection
                } else {
                    TextField("Base URL", text: configuration.baseURL, prompt: Text("http://localhost:11434/v1"))
                        .font(.body.monospaced())
                    TextField("Model", text: configuration.model, prompt: Text("llama3.3"))
                        .font(.body.monospaced())
                    Text("Any server that speaks the OpenAI chat completions API with tool calling: Ollama, LM Studio, vLLM, llama.cpp or a hosted endpoint. Local models need no key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("API key") {
                HStack {
                    SecureField(keyPlaceholder, text: $apiKeyDraft)
                        .onSubmit(saveKey)
                    Button("Save") { saveKey() }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if settings.hasAPIKey {
                        Button("Remove") {
                            do { try settings.removeAPIKey(); keyMessage = "Key removed." } catch { keyMessage = error.localizedDescription }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: settings.hasAPIKey ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(settings.hasAPIKey ? .green : .secondary)
                    Text(keyMessage ?? keyHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("MCP server") {
                Toggle("Expose Tepfasonic's tools to Claude Desktop and Claude Code", isOn: $mcp.isEnabled)
                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                        .onAppear { portText = String(mcp.port) }
                    Button("Apply") { applyPort() }
                        .disabled(Int(portText) == mcp.port)
                    Spacer()
                    if mcp.isRunning {
                        Label("Listening on \(mcp.httpURL)", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
                    } else if let error = mcp.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else {
                        Label("Off", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                Text("The same six tools, guardrails, approval sheet and audit log as the panel. Streamable HTTP on localhost with a bearer token; the stdio bridge inside the app launches Tepfasonic when needed. Paste one of these into the client:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConfigLine(title: "Claude Code", text: mcp.claudeCodeCommand)
                ConfigLine(title: "Claude Code (HTTP, no bridge)", text: mcp.claudeCodeHTTPCommand)
                ConfigLine(title: "Claude Desktop · claude_desktop_config.json", text: mcp.claudeDesktopSnippet)
                HStack {
                    Button("Regenerate Token") { mcp.regenerateToken() }
                    Text("Clients using the HTTP line must be updated after regenerating.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            AgentAuditLogSection()
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.bottom)
        .task(id: settings.configuration.kind) {
            // The list is public, so loading it never asks for the key or the vault.
            guard settings.configuration.kind == .caimex, caimexModels.isEmpty else { return }
            await loadCaimexModels()
        }
        .onChange(of: settings.configuration.kind) { _, _ in
            // One reset for every kind change, however it happens: a key typed for one provider must never
            // be saved to another, and the status and Caimex field state belong to the old provider.
            apiKeyDraft = ""
            keyMessage = nil
            caimexTypingCustom = false
            caimexError = nil
        }
    }

    @ViewBuilder
    private var caimexModelSection: some View {
        HStack {
            Picker("Model", selection: caimexModelBinding) {
                ForEach(caimexChoices.ids, id: \.self) { id in
                    Text(id + (id == LLMProviderConfiguration.defaultCaimexModel ? " (default)" : "")).tag(id)
                }
                Text("Other…").tag(Self.customModelTag)
            }
            Button {
                Task { await loadCaimexModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(caimexLoading)
            .help("Refresh the model list")
        }
        if caimexTypingCustom {
            TextField("Model ID", text: configuration.model)
                .font(.body.monospaced())
        }
        if caimexLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading models…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let caimexError {
            Label(caimexError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Text("The agent needs a model with tool calling; the gateway's list does not say which models support it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func loadCaimexModels() async {
        caimexLoadGeneration += 1
        let generation = caimexLoadGeneration
        caimexLoading = true
        caimexError = nil
        do {
            // No key: the model list is public and must not unlock the vault or prompt for Touch ID.
            let models = try await CaimexModelCatalogue().models()
            guard generation == caimexLoadGeneration else { return }
            caimexModels = models
        } catch is CancellationError {
            // The provider changed or the screen closed; a cancelled load is not an error.
            guard generation == caimexLoadGeneration else { return }
        } catch let error as URLError where error.code == .cancelled {
            // Same as above: URLSession reports cancellation as an error.
            guard generation == caimexLoadGeneration else { return }
        } catch {
            // A stale load must not overwrite a newer one's result or spinner.
            guard generation == caimexLoadGeneration else { return }
            caimexError = error.localizedDescription
        }
        // Only the latest load clears the spinner; a cancelled older one leaves it to its successor.
        guard generation == caimexLoadGeneration else { return }
        caimexLoading = false
    }

    private var keyPlaceholder: String {
        if settings.hasAPIKey { return "Saved in the Keychain — paste to replace" }
        switch kind {
        case .anthropic: return "sk-ant-…"
        case .caimex: return "Caimex API key"
        case .openAICompatible: return "Optional key for a hosted endpoint"
        }
    }

    private var keyHelp: String {
        if settings.hasAPIKey {
            return "A key is saved in your login Keychain for \(kind.displayName), scoped to this app, behind the same lock as your passwords. Each provider keeps its own key."
        }
        switch kind {
        case .anthropic:
            return "Bring your own Anthropic key: it is stored in the Keychain and sent only to Anthropic. Each provider keeps its own key."
        case .caimex:
            return "Bring your own Caimex key: it is stored in the Keychain and sent only to the Caimex gateway. Each provider keeps its own key."
        case .openAICompatible:
            return "Optional for local servers. A key here is stored in the Keychain and sent only to the endpoint you typed. Each provider keeps its own key."
        }
    }

    private func saveKey() {
        do {
            try settings.setAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            keyMessage = "Key saved."
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    private func applyPort() {
        guard let port = Int(portText), (1024...65535).contains(port) else {
            portText = String(mcp.port)
            return
        }
        mcp.port = port
    }
}

/// A read-only config line with a Copy button.
private struct ConfigLine: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Every command the agent or an MCP client proposed, with the decision and result.
struct AgentAuditLogSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AgentAuditEntry.timestamp, order: .reverse) private var entries: [AgentAuditEntry]
    @State private var isConfirmingClear = false
    @State private var message: String?

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("Nothing yet. Every command proposed by the panel or an MCP client is recorded here with the host, the decision, the exit status and when it ran.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(entries.prefix(200)) { entry in
                    AgentAuditRow(entry: entry)
                }
                .frame(height: 240)
                if entries.count > 200 {
                    Text("Showing the latest 200 of \(entries.count); the export has them all.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Export JSON…") { export() }
                    .disabled(entries.isEmpty)
                Button("Clear…", role: .destructive) { isConfirmingClear = true }
                    .disabled(entries.isEmpty)
                    .confirmationDialog("Clear the audit log?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                        Button("Clear Audit Log", role: .destructive) { clear() }
                    }
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Audit log")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tepfasonic-agent-audit-\(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try AgentAuditRecord.exportJSON(entries.map(AgentAuditRecord.init))
            try data.write(to: url, options: [.atomic])
            message = "Exported \(entries.count) entries."
        } catch {
            message = error.localizedDescription
        }
    }

    private func clear() {
        for entry in entries { modelContext.delete(entry) }
        try? modelContext.save()
        message = "Audit log cleared."
    }
}

private struct AgentAuditRow: View {
    let entry: AgentAuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(entry.hostName).fontWeight(.medium)
                Text(entry.tool).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(entry.source == .mcp ? "MCP" : "panel").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                Spacer()
                if let status = entry.exitStatus { Text("exit \(status)").font(.caption).foregroundStyle(status == 0 ? Color.secondary : Color.orange) }
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.command).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 4) {
                Text(entry.decision.displayName)
                if let proposed = entry.proposedCommand { Text("· was: \(proposed)").lineLimit(1) }
                if !entry.reason.isEmpty { Text("· \(entry.reason)").lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.decision {
        case .autoAllowed: "checkmark.circle"
        case .approved: "hand.thumbsup"
        case .edited: "pencil.circle"
        case .denied: "hand.raised"
        case .blocked: "nosign"
        case .cancelled: "stop.circle"
        }
    }

    private var color: Color {
        switch entry.decision {
        case .autoAllowed, .approved, .edited: .green
        case .denied, .blocked: .red
        case .cancelled: .orange
        }
    }
}
