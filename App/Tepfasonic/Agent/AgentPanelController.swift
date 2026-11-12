import AppKit
import Foundation
import Observation
import SwiftData
import TepfaAgent
import TepfaCore
import TepfaTerminal
import UniformTypeIdentifiers

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
    /// Files attached to the message being written, in the order they were added.
    private(set) var pendingAttachments: [AgentAttachment] = []
    /// Why the last file could not be attached.
    private(set) var attachmentError: String?
    /// The earlier user message being rewritten in the composer. Sending
    /// replaces it and everything after it.
    private(set) var editing: AgentMessage?
    private var providerConfiguration: LLMProviderConfiguration?

    /// Copies of attached files live here, one folder per attachment.
    static var attachmentsDirectory: URL {
        AppPaths.applicationSupport.appending(path: "Agent/Attachments", directoryHint: .isDirectory)
    }

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
        cancelEditing()
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
        cancelEditing()
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

    // MARK: Attachments

    /// Imports each file (images, PDFs, Word documents, text) into the pending list.
    func attach(urls: [URL]) {
        for url in urls {
            do {
                let file = try AttachmentImporter.importFile(at: url, into: Self.attachmentsDirectory)
                pendingAttachments.append(file)
                attachmentError = nil
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ file: AgentAttachment) {
        pendingAttachments.removeAll { $0.id == file.id }
        // A file that came with the message being edited still belongs to that
        // message until the edit is sent, so its copy stays on disk.
        if editing?.attachments.contains(where: { $0.id == file.id }) != true {
            AttachmentImporter.discard(file)
        }
        attachmentError = nil
    }

    /// The standard open panel, limited to what the models can read.
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.message = "Images, PDFs, Word documents and text files such as logs, configs, code and CSV."
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .xml, .yaml, .propertyList, .commaSeparatedText, .log, .shellScript, .data]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.attach(urls: panel.urls) }
        }
    }

    // MARK: Copying and editing

    /// The whole conversation as plain text on the clipboard.
    func copyConversation() {
        guard let session else { return }
        Self.copy(AgentTranscript.plainText(session.messages))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether this message can be rewritten: a user turn the person typed
    /// (not a tool result), while no reply is running.
    func canEdit(_ message: AgentMessage) -> Bool {
        message.role == .user && (!message.text.isEmpty || !message.attachments.isEmpty) && session?.isRunning != true
    }

    /// Starts rewriting an earlier message: its files go back in the pending
    /// list and the caller puts its text in the composer. Nothing in the
    /// transcript changes until the edit is sent.
    func beginEditing(_ message: AgentMessage) {
        guard canEdit(message) else { return }
        cancelEditing()
        editing = message
        let present = Set(pendingAttachments.map(\.id))
        pendingAttachments = message.attachments.filter { !present.contains($0.id) && !$0.isMissing } + pendingAttachments
    }

    /// Leaves the earlier message as it was.
    func cancelEditing() {
        guard let message = editing else { return }
        editing = nil
        let original = Set(message.attachments.map(\.id))
        pendingAttachments.removeAll { original.contains($0.id) }
    }

    // MARK: Sending

    var canSend: Bool {
        session?.isRunning != true
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }
        let session = session ?? makeSession(messages: [])
        self.session = session
        guard session.canSend else { return }
        let files = pendingAttachments
        let edited = editing
        pendingAttachments = []
        attachmentError = nil
        setupError = nil
        Task {
            do {
                if providerConfiguration != settings.configuration || session.provider is PlaceholderProvider {
                    session.provider = try await settings.makeProvider()
                    providerConfiguration = settings.configuration
                }
                session.systemPrompt = systemPrompt()
                if let edited, editing?.id == edited.id {
                    // The rewritten message takes the place of the original and of
                    // every reply that followed it. Files taken off the edit go with it.
                    editing = nil
                    session.rewind(to: edited.id)
                    let kept = Set(files.map(\.id))
                    for file in edited.attachments where !kept.contains(file.id) { AttachmentImporter.discard(file) }
                }
                session.send(trimmed, attachments: files)
            } catch {
                // Keep the files so the user can try again once the key is set.
                pendingAttachments = files + pendingAttachments
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

#if DEBUG
extension AgentPanelController {
    /// `--qa-agent-demo`: a finished conversation with two attachments, a tool
    /// call and a real generated PDF, so the panel can be screenshotted without a key.
    func seedDemoConversation() {
        let directory = Self.attachmentsDirectory.appending(path: "demo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appending(path: "grafana-disk.png")
        try? Self.demoImage().write(to: imageURL)
        let logURL = directory.appending(path: "nginx-error.log")
        try? Data("2026/11/11 06:12:01 [error] 1182#1182: *44 open() \"/var/www/html/favicon.ico\" failed (2: No such file or directory)\n2026/11/11 06:12:04 [crit] 1182#1182: *45 pwrite() \"/var/cache/nginx/proxy_temp/3/01/0000000013\" failed (28: No space left on device)\n".utf8).write(to: logURL)
        let image = AgentAttachment(fileName: "grafana-disk.png", mediaType: "image/png", byteCount: (try? Data(contentsOf: imageURL).count) ?? 0, path: imageURL.path)
        let log = AgentAttachment(fileName: "nginx-error.log", mediaType: "text/plain", byteCount: (try? Data(contentsOf: logURL).count) ?? 0, path: logURL.path)

        let runner = AgentToolRunner(host: toolHost, source: .agentPanel)
        let report = """
        ## Summary
        The root volume on **build-box** is at 91% and nginx has started failing writes to its proxy cache. Two log directories account for most of the growth.

        ## Volumes
        | Mount | Size | Used | Free | Use |
        |-------|------|------|------|-----|
        | / | 80 GB | 73 GB | 7.0 GB | 91% |
        | /data | 500 GB | 212 GB | 288 GB | 42% |

        ## Largest directories
        1. `/var/log/nginx` — 18 GB (access logs, no rotation since October)
        2. `/var/cache/nginx` — 11 GB
        3. `/home/ubuntu/.cache/pip` — 6 GB

        ## Recommendations
        - Enable `logrotate` for nginx with 14 days of compressed history.
        - Clear the pip cache and the stale proxy cache.
        - Alert at 80% so the next fill-up is caught early.

        > Nothing was changed on the host; every command above was read-only.
        """
        let created = (try? runner.createDocument(fileName: "Disk usage report", format: .pdf, title: "Disk usage report — build-box", content: report)) ?? ""
        let messages: [AgentMessage] = [
            .user("Here is this morning's Grafana panel and the nginx error log. Check the disks on build-box and give me a PDF report I can send to the team.", attachments: [image, log]),
            AgentMessage(role: .assistant, blocks: [
                .text("The log shows nginx failing with *No space left on device*, so I'll start with the volumes on build-box."),
                .toolUse(id: "demo-1", name: "run_command", input: ["host": "build-box", "command": "df -h / /data && sudo du -xsh /var/log/nginx /var/cache/nginx /home/ubuntu/.cache/pip", "reason": "See which volume is full and what is filling it"]),
            ], model: "claude-opus-5-5"),
            AgentMessage(role: .user, blocks: [
                .toolResult(toolUseID: "demo-1", content: "<command_output host=\"build-box\" exit_status=\"0\" duration_ms=\"412\" truncated=\"false\">\nFilesystem      Size  Used Avail Use% Mounted on\n/dev/sda1        80G   73G  7.0G  91% /\n/dev/sdb1       500G  212G  288G  42% /data\n18G\t/var/log/nginx\n11G\t/var/cache/nginx\n6.0G\t/home/ubuntu/.cache/pip\n</command_output>", isError: false),
            ]),
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: "demo-2", name: "create_document", input: ["file_name": "Disk usage report", "format": "pdf", "title": "Disk usage report — build-box", "content": .string(report)]),
            ], model: "claude-opus-5-5"),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseID: "demo-2", content: created, isError: false)]),
            AgentMessage(role: .assistant, blocks: [
                .text("**Disk usage report** is ready. The root volume is at 91%, driven by 18 GB of unrotated nginx access logs and an 11 GB proxy cache; the report lists the volumes, the three largest directories and three fixes, starting with `logrotate`. Nothing was changed on the host."),
            ], model: "claude-opus-5-5"),
        ]
        newConversation()
        session?.replace(messages: messages)
    }

    /// A small chart-like PNG standing in for a dashboard screenshot.
    private static func demoImage() -> Data {
        let size = CGSize(width: 480, height: 280)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.09, green: 0.1, blue: 0.14, alpha: 1).setFill()
            rect.fill()
            let values: [CGFloat] = [0.42, 0.47, 0.51, 0.58, 0.63, 0.7, 0.74, 0.8, 0.86, 0.91]
            let path = NSBezierPath()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: 30 + CGFloat(index) * 46, y: 30 + value * 220)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            NSColor(srgbRed: 0.42, green: 0.69, blue: 1, alpha: 1).setStroke()
            path.lineWidth = 3
            path.stroke()
            NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 0.9).setStroke()
            let limit = NSBezierPath()
            limit.move(to: CGPoint(x: 20, y: 30 + 0.8 * 220))
            limit.line(to: CGPoint(x: 460, y: 30 + 0.8 * 220))
            limit.setLineDash([6, 4], count: 2, phase: 0)
            limit.lineWidth = 1.5
            limit.stroke()
            let label = NSAttributedString(string: "Disk used — / on build-box", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
            label.draw(at: CGPoint(x: 20, y: 256))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
#endif

/// Stands in until the real provider is built from settings on the first send.
private struct PlaceholderProvider: LLMProvider {
    var displayName: String { "none" }
    var modelName: String { "" }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentSetupError(message: "No model is configured.")) }
    }
}
