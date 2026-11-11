import AppKit
import SwiftUI
import TepfaAgent
import TepfaCore
import TepfaTerminal
import UniformTypeIdentifiers

/// The Claude panel: scope and conversation chips, the transcript as message
/// bubbles, file cards for generated documents, and a composer that takes
/// attachments from a button or a drop.
struct AgentPanelView: View {
    @Environment(AgentPanelController.self) private var controller
    @Environment(AppState.self) private var appState
    @Environment(\.palette) private var palette
    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeDivider()
            if let session = controller.session, !session.messages.isEmpty || session.isRunning {
                AgentTranscriptView(session: session)
            } else {
                emptyState
            }
            ChromeDivider()
            statusLine
            composer
        }
        .frame(minWidth: 320)
        .overlay {
            if dropTargeted {
                Design.shape(Design.radiusLarge)
                    .strokeBorder(palette.accent ?? .accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(6)
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(palette.raised, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            attach(providers)
        }
        .onAppear {
            controller.focusOnWorkspaceIfIdle()
            composerFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    controller.focus(.all)
                } label: {
                    Label("All hosts (\(controller.hosts.count))", systemImage: "server.rack")
                }
                // A group scopes the conversation to its hosts: Claude sees only
                // those and the tools run only there.
                if !controller.groups.isEmpty {
                    Section("Groups") {
                        ForEach(controller.groups) { group in
                            Button {
                                controller.focus(.group(group.uuid))
                            } label: {
                                Label("\(group.name) (\(group.hosts.count))", systemImage: "folder")
                            }
                        }
                    }
                }
                Section("Hosts") {
                    ForEach(controller.hosts) { host in
                        Button {
                            controller.focus(.host(host.uuid))
                        } label: {
                            Label(host.name, systemImage: "desktopcomputer")
                        }
                    }
                }
            } label: {
                Label(controller.scopeTitle, systemImage: scopeIcon)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pill()
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
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide the Claude panel (⌘⇧A)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    private var scopeIcon: String {
        switch controller.scope {
        case .all: "server.rack"
        case .host: "desktopcomputer"
        case .group: "folder"
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            IconTile(systemImage: "sparkles", color: palette.accent ?? .accentColor, size: 56)
            Text("Ask Claude")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("Claude inspects and operates your hosts over SSH, reads files you attach, and writes reports as PDF or Word. Every command shows in an agent tab, and the host's permission mode decides what asks first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            VStack(spacing: 6) {
                suggestion("What is using the most disk on \(controller.scopeTitle == "All hosts" ? "each host" : controller.scopeTitle)?")
                suggestion("Check the nginx error log for the last hour and summarise it.")
                suggestion("Write a PDF report of CPU, memory and disk for the team.")
            }
            .padding(.top, 4)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            draft = text
            composerFocused = true
        } label: {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .card(padding: 10)
        .frame(maxWidth: 340)
    }

    // MARK: Status and composer

    @ViewBuilder
    private var statusLine: some View {
        let session = controller.session
        HStack(spacing: 8) {
            if let error = controller.setupError ?? controller.attachmentError ?? session?.lastError {
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
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var composer: some View {
        ComposerView(draft: $draft, focused: $composerFocused)
    }

    /// Finder drops arrive as file URLs; everything else is ignored.
    private func attach(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty else { return false }
        for provider in candidates {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in controller.attach(urls: [url]) }
            }
        }
        return true
    }
}

// MARK: - Composer

/// The composer lives in its own view so that typing and dictation — which
/// update the draft frequently — invalidate only this subtree, not the panel's
/// transcript, which is backed by an `NSScrollView` (a platform view). On
/// macOS 26/27 a view/responder change under the cursor can trip a
/// use-after-free in SwiftUI's own hover hit-testing (`NSViewResponder`
/// `.platformCurrentEvent`), a system bug that crashes many apps; keeping the
/// churn out of the transcript, and not animating the microphone, makes that
/// far less likely to fire while recording.
private struct ComposerView: View {
    @Environment(AgentPanelController.self) private var controller
    @Environment(\.palette) private var palette
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @State private var dictation = SpeechDictation()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !controller.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(controller.pendingAttachments) { file in
                            AttachmentChip(file: file, onAccent: false) { controller.removeAttachment(file) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    controller.pickFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(palette.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach images, PDFs, Word documents or text files (or drop them here)")
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused(focused)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(palette.raised, in: Design.shape(Design.radiusBubble))
                    .overlay(Design.shape(Design.radiusBubble).strokeBorder(focused.wrappedValue ? (palette.accent ?? .accentColor).opacity(0.6) : palette.separator, lineWidth: focused.wrappedValue ? 1 : 0.5))
                if dictation.isAvailable {
                    Button {
                        toggleDictation()
                    } label: {
                        // A constant point size and fixed frame: the symbol swap
                        // must not resize or animate, to avoid churning the
                        // responder tree while the cursor is over the button.
                        Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(dictation.isListening ? Color.red.opacity(0.16) : palette.raised, in: Circle())
                            .foregroundStyle(dictation.isListening ? Color.red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(dictation.isListening ? "Stop dictation" : "Dictate your message — speech stays on this Mac")
                }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? (palette.accent ?? .accentColor) : .secondary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send (⌘↩)")
            }
            if let message = dictation.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
        .padding(10)
    }

    private func toggleDictation() {
        guard !dictation.isListening else {
            dictation.stop()
            focused.wrappedValue = true
            return
        }
        let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictation.start { transcript in
            draft = base.isEmpty ? transcript : base + " " + transcript
        }
    }

    private var placeholder: String {
        if dictation.isListening { return "Listening…" }
        return controller.pendingAttachments.isEmpty ? "Ask Claude about \(controller.scopeTitle)…" : "Say what to do with the files…"
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.pendingAttachments.isEmpty) && controller.canSend
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        controller.send(text)
    }
}

// MARK: - Transcript

struct AgentTranscriptView: View {
    @Environment(\.palette) private var palette
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        AgentMessageView(message: message, results: results)
                    }
                    if session.isRunning {
                        AgentStreamingView(session: session)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.messages.count) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: session.streamingText.count) { _, _ in proxy.scrollTo("bottom") }
            .schemeEdges(palette)
        }
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage
    let results: [String: (content: String, isError: Bool)]
    @Environment(\.palette) private var palette

    var body: some View {
        if message.role == .user {
            // Tool results travel in user turns but are shown with their tool call.
            let text = message.text
            let files = message.attachments
            if !text.isEmpty || !files.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !files.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(files) { file in
                                    AttachmentChip(file: file, onAccent: true, onRemove: nil)
                                }
                            }
                        }
                        if !text.isEmpty {
                            Text(text)
                                .textSelection(.enabled)
                        }
                    }
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.accent ?? Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: Design.radiusBubble, bottomLeadingRadius: Design.radiusBubble, bottomTrailingRadius: 5, topTrailingRadius: Design.radiusBubble, style: .continuous))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
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
                    case .toolResult, .attachment:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentStreamingView: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.streamingThinking.isEmpty {
                ThinkingView(text: session.streamingThinking, expanded: true)
            }
            if !session.streamingText.isEmpty {
                MarkdownText(session.streamingText)
            }
        }
    }
}

// MARK: - Attachments and documents

/// A file on a message or in the composer: thumbnail or icon, name, size.
struct AttachmentChip: View {
    let file: AgentAttachment
    /// Drawn on the accent-coloured user bubble.
    let onAccent: Bool
    let onRemove: (() -> Void)?
    @Environment(\.palette) private var palette
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 7) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(Design.shape(7))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(onAccent ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(palette.raised), in: Design.shape(7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.note.map { "\(file.sizeDescription) · \($0)" } ?? file.sizeDescription)
                    .font(.caption2)
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .frame(maxWidth: 160, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
            }
        }
        .padding(5)
        .background(onAccent ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(palette.raised), in: Design.shape(Design.radiusMedium))
        .overlay {
            if !onAccent { Design.shape(Design.radiusMedium).strokeBorder(palette.separator, lineWidth: 0.5) }
        }
        .task(id: file.id) {
            guard file.kind == .image, !file.isMissing else { return }
            let url = file.url
            thumbnail = await Task.detached { NSImage(contentsOf: url) }.value
        }
        .help(file.isMissing ? "\(file.fileName) is no longer on this Mac" : file.fileName)
    }

    private var icon: String {
        switch file.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: file.fileName.lowercased().hasSuffix(".docx") ? "doc.text" : "doc.plaintext"
        }
    }
}

/// A document the agent wrote: open it, show it in Finder, or save a copy elsewhere.
struct GeneratedDocumentCard: View {
    let reference: AgentDocumentReference
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemImage: icon, color: color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(reference.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reference.exists ? reference.summary : "\(reference.summary) · moved or deleted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Open") { NSWorkspace.shared.open(reference.url) }
                .controlSize(.small)
                .disabled(!reference.exists)
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reference.url]) }
                Button("Save As…") { saveCopy() }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reference.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!reference.exists)
        }
        .card(padding: 10)
        .help(reference.path)
    }

    private var icon: String {
        switch reference.format {
        case .pdf: "doc.richtext.fill"
        case .docx: "doc.text.fill"
        case .html: "globe"
        case .md, .txt: "text.alignleft"
        case .csv: "tablecells.fill"
        }
    }

    private var color: Color {
        switch reference.format {
        case .pdf: Color(red: 0.93, green: 0.33, blue: 0.3)
        case .docx: Color(red: 0.17, green: 0.45, blue: 0.85)
        case .html: Color(red: 0.95, green: 0.55, blue: 0.15)
        case .md, .txt: Color(red: 0.5, green: 0.53, blue: 0.6)
        case .csv: Color(red: 0.2, green: 0.65, blue: 0.4)
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = reference.name
        if let type = UTType(filenameExtension: reference.format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: reference.url, to: destination)
        }
    }
}

// MARK: - Markdown

/// Block-level Markdown for replies: headings, paragraphs, lists, code, tables and quotes.
struct MarkdownText: View {
    let text: String
    @Environment(\.palette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        let document = MarkdownDocument(parsing: text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .foregroundStyle(palette.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let inlines):
            Text(Self.attributed(inlines))
                .font(level == 1 ? .title3.weight(.semibold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                .padding(.top, 2)
        case .paragraph(let inlines):
            Text(Self.attributed(inlines))
        case .quote(let inlines):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(palette.separator).frame(width: 3)
                Text(Self.attributed(inlines)).foregroundStyle(.secondary)
            }
        case .code(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .padding(8)
            }
            .background(palette.raised, in: Design.shape(Design.radiusSmall))
        case .rule:
            ChromeDivider().padding(.vertical, 2)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(Self.ordinal(items, at: index))." : (item.level == 0 ? "•" : "◦"))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.attributed(item.inlines))
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(Self.attributed(cell)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.attributed(cell)).font(.callout)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(palette.raised, in: Design.shape(Design.radiusSmall))
        }
    }

    private static func ordinal(_ items: [MarkdownDocument.ListItem], at index: Int) -> Int {
        var count = 0
        for i in 0...index where items[i].level == items[index].level {
            if i > 0, let reset = items[..<i].lastIndex(where: { $0.level < items[index].level }), items[(reset + 1)...i].allSatisfy({ $0.level >= items[index].level }) {
                // Numbering restarts after a shallower item.
                if items[(reset + 1)..<i].filter({ $0.level == items[index].level }).isEmpty { count = 0 }
            }
            count += 1
        }
        return count
    }

    static func attributed(_ inlines: [MarkdownDocument.Inline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let text):
                result += AttributedString(text)
            case .bold(let text):
                var piece = AttributedString(text)
                piece.inlinePresentationIntent = .stronglyEmphasized
                result += piece
            case .italic(let text):
                var piece = AttributedString(text)
                piece.inlinePresentationIntent = .emphasized
                result += piece
            case .code(let text):
                var piece = AttributedString(text)
                piece.inlinePresentationIntent = .code
                result += piece
            case .link(let text, let url):
                var piece = AttributedString(text)
                piece.link = URL(string: url)
                piece.underlineStyle = .single
                result += piece
            }
        }
        return result
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

/// A tool call with its result, collapsed to one line until clicked. A
/// finished `create_document` shows the file card instead.
private struct ToolCallView: View {
    let name: String
    let input: JSONValue
    let result: (content: String, isError: Bool)?
    @Environment(\.palette) private var palette
    @State private var isExpanded = false

    private var document: AgentDocumentReference? {
        guard AgentToolName(rawValue: name) == .createDocument, let result, !result.isError else { return nil }
        return AgentDocumentReference.parse(from: result.content)
    }

    private var summary: String {
        let host = input["host"]?.stringValue ?? ""
        switch AgentToolName(rawValue: name) {
        case .runCommand: return input["command"]?.stringValue ?? ""
        case .readFile: return "read \(input["path"]?.stringValue ?? "")"
        case .writeFile: return "write \(input["path"]?.stringValue ?? "")"
        case .sftpTransfer: return "\(input["direction"]?.stringValue ?? "transfer") \(input["remote_path"]?.stringValue ?? "")"
        case .readTerminalBuffer: return "terminal on \(host)"
        case .listHosts: return "list hosts"
        case .createDocument: return "\(input["file_name"]?.stringValue ?? "document") (\(input["format"]?.stringValue ?? "?"))"
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
        if let document {
            GeneratedDocumentCard(reference: document)
        } else {
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
            .card(padding: 8, radius: Design.radiusSmall)
        }
    }
}
