import AppKit
import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Inline completions from history and snippets, shown under the caret while
/// typing at a prompt. → accepts, ⌥↑/⌥↓ move, Esc hides.
struct SuggestionsOverlay: View {
    @Bindable var session: TerminalSession
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TerminalPreferences.suggestionsKey) private var enabled = true
    @State private var model = SuggestionsModel()

    var body: some View {
        GeometryReader { geometry in
            if enabled, model.isVisible, !model.items.isEmpty {
                // The terminal view is not flipped: its caret frame measures from the bottom.
                let caret = model.caretFrame
                let caretTop = geometry.size.height - caret.maxY
                let caretBottom = geometry.size.height - caret.minY
                let listHeight = CGFloat(model.items.count) * 24 + 8
                let below = caretBottom + 4 + listHeight <= geometry.size.height
                let y = below ? caretBottom + 4 : max(0, caretTop - listHeight - 4)
                let x = min(max(0, caret.minX), max(0, geometry.size.width - 420))
                SuggestionsList(items: model.items, highlighted: model.highlighted, typed: session.typedLine) { index in
                    model.accept(index: index, session: session)
                }
                .frame(width: 420, height: listHeight)
                .offset(x: x, y: y)
            }
        }
        .allowsHitTesting(model.isVisible)
        .onChange(of: session.typedLine) { _, _ in model.typedLineChanged(session: session, context: modelContext) }
        .onChange(of: session.promptPhase) { _, _ in model.typedLineChanged(session: session, context: modelContext) }
        .onChange(of: session.isConnected) { _, _ in model.typedLineChanged(session: session, context: modelContext) }
        .onChange(of: enabled) { _, _ in model.typedLineChanged(session: session, context: modelContext) }
        .onAppear { model.install(session: session) }
        .onDisappear { model.uninstall() }
    }
}

struct Suggestion: Identifiable, Hashable {
    enum Kind: Hashable { case history(host: String), snippet(name: String) }
    let command: String
    let kind: Kind
    var id: String { command }
}

@MainActor
@Observable
final class SuggestionsModel {
    var items: [Suggestion] = []
    var highlighted = 0
    var isVisible = false
    var caretFrame = CGRect.zero
    private var dismissedFor: String?
    private var monitor: Any?
    private weak var session: TerminalSession?
    private var refreshTask: Task<Void, Never>?

    func install(session: TerminalSession) {
        self.session = session
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, !self.items.isEmpty, let session = self.session,
                  let view = session.attachedView, event.window === view.window, view.window?.firstResponder === view else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (event.keyCode, flags) {
            case (124, []): // →
                self.accept(index: self.highlighted, session: session)
                return nil
            case (125, .option): // ⌥↓
                self.highlighted = (self.highlighted + 1) % self.items.count
                return nil
            case (126, .option): // ⌥↑
                self.highlighted = (self.highlighted - 1 + self.items.count) % self.items.count
                return nil
            case (53, []): // Esc
                self.dismissedFor = session.typedLine
                self.isVisible = false
                return nil
            default:
                return event
            }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTask?.cancel()
    }

    func typedLineChanged(session: TerminalSession, context: ModelContext) {
        let typed = session.typedLine
        guard TerminalPreferences.suggestions, session.isConnected, session.typedLineIsReliable,
              session.promptPhase != .running, typed.count >= 2, dismissedFor != typed else {
            isVisible = false
            items = []
            return
        }
        if dismissedFor != nil, !typed.hasPrefix(dismissedFor ?? "") { dismissedFor = nil }
        items = Self.suggestions(for: typed, host: session.host.name, context: context)
        highlighted = 0
        isVisible = !items.isEmpty
        updateCaret(session: session)
        // The caret moves once the echo arrives; look again shortly.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.updateCaret(session: session)
        }
    }

    private func updateCaret(session: TerminalSession) {
        if let view = session.attachedView as? TepfaTerminalView {
            caretFrame = view.caretFrame
        }
    }

    func accept(index: Int, session: TerminalSession) {
        guard items.indices.contains(index) else { return }
        let command = items[index].command
        dismissedFor = command
        isVisible = false
        session.replaceTypedLine(with: command)
    }

    static func suggestions(for typed: String, host: String, context: ModelContext, limit: Int = 6) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen: Set<String> = []

        var descriptor = FetchDescriptor<CommandHistoryEntry>(
            predicate: #Predicate { $0.command.starts(with: typed) },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 60
        let prefixMatches = (try? context.fetch(descriptor)) ?? []
        // Entries from this host first, then the rest, newest first.
        for entry in prefixMatches.sorted(by: { ($0.hostName == host ? 0 : 1, -$0.startedAt.timeIntervalSinceReferenceDate) < ($1.hostName == host ? 0 : 1, -$1.startedAt.timeIntervalSinceReferenceDate) }) {
            guard entry.command != typed, seen.insert(entry.command).inserted else { continue }
            out.append(Suggestion(command: entry.command, kind: .history(host: entry.hostName)))
            if out.count >= limit { return out }
        }

        let snippets = (try? context.fetch(FetchDescriptor<Snippet>(sortBy: [SortDescriptor(\.useCount, order: .reverse)]))) ?? []
        let needle = typed.lowercased()
        for snippet in snippets where snippet.variables.isEmpty && !snippet.command.contains(where: \.isNewline) {
            guard snippet.command.lowercased().hasPrefix(needle) || snippet.name.lowercased().hasPrefix(needle) else { continue }
            guard snippet.command != typed, seen.insert(snippet.command).inserted else { continue }
            out.append(Suggestion(command: snippet.command, kind: .snippet(name: snippet.name)))
            if out.count >= limit { return out }
        }

        if out.count < limit {
            var contains = FetchDescriptor<CommandHistoryEntry>(
                predicate: #Predicate { $0.command.contains(typed) },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
            contains.fetchLimit = 40
            for entry in (try? context.fetch(contains)) ?? [] {
                guard entry.command != typed, seen.insert(entry.command).inserted else { continue }
                out.append(Suggestion(command: entry.command, kind: .history(host: entry.hostName)))
                if out.count >= limit { break }
            }
        }
        return out
    }
}

private struct SuggestionsList: View {
    let items: [Suggestion]
    let highlighted: Int
    let typed: String
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: item.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    highlightedText(item.command)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(label(for: item.kind))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if index == highlighted {
                        Text("→").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index == highlighted ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private func highlightedText(_ command: String) -> Text {
        if command.hasPrefix(typed) {
            return Text(typed) + Text(command.dropFirst(typed.count)).foregroundStyle(.secondary)
        }
        return Text(command)
    }

    private func icon(for kind: Suggestion.Kind) -> String {
        switch kind {
        case .history: "clock.arrow.circlepath"
        case .snippet: "text.badge.star"
        }
    }

    private func label(for kind: Suggestion.Kind) -> String {
        switch kind {
        case .history(let host): host
        case .snippet(let name): name
        }
    }
}
