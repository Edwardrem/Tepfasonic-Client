import AppKit
import SwiftTerm
import SwiftUI
import TepfaCore
import TepfaTerminal
import UniformTypeIdentifiers

/// Colour scheme editor: pick a scheme on the left, edit its colours with a
/// live sample terminal on the right, save, import, export and share.
struct ThemeEditorView: View {
    static let windowID = "theme-editor"

    @Environment(ThemeStore.self) private var themes
    @Environment(AppState.self) private var appState
    @State private var selectedID: String?
    @State private var draft: TerminalTheme?
    @State private var message: String?

    private var selectedIsBuiltIn: Bool { draft?.isBuiltIn ?? true }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Bundled") {
                    ForEach(TerminalTheme.bundled) { theme in
                        row(theme).tag(theme.id)
                    }
                }
                Section("Mine") {
                    if themes.userThemes.isEmpty {
                        Text("Duplicate a bundled scheme or import one to start.").foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(themes.userThemes) { theme in
                        row(theme).tag(theme.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("Import Scheme File…") { importFile() }
                        Button("New from Current") { duplicate() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let draftBinding = Binding($draft) {
                editor(draftBinding)
            } else {
                ContentUnavailableView("Choose a scheme", systemImage: "paintpalette")
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = themes.globalThemeID }
            load()
        }
        .onChange(of: selectedID) { _, _ in load() }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func row(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(theme.ansi.prefix(6).enumerated()), id: \.offset) { _, hex in
                    RoundedRectangle(cornerRadius: 2).fill(HostColor.color(hex) ?? .clear).frame(width: 8, height: 12)
                }
            }
            .padding(3)
            .background(HostColor.color(theme.background) ?? .clear, in: RoundedRectangle(cornerRadius: 4))
            Text(theme.name).lineLimit(1)
            Spacer()
            if theme.id == themes.globalThemeID || (themes.autoSwitch != .off && (theme.id == themes.lightThemeID || theme.id == themes.darkThemeID)) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func load() {
        guard let selectedID, let theme = themes.theme(id: selectedID) else {
            draft = nil
            return
        }
        draft = theme
        message = nil
    }

    private func editor(_ draft: Binding<TerminalTheme>) -> some View {
        HSplitView {
            Form {
                Section {
                    TextField("Name", text: draft.name)
                        .disabled(selectedIsBuiltIn)
                    Toggle("Dark scheme", isOn: draft.isDark)
                        .disabled(selectedIsBuiltIn)
                    if selectedIsBuiltIn {
                        Text("Bundled schemes are read-only. Duplicate to edit.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Text and background") {
                    colorRow("Foreground", hex: draft.foreground)
                    colorRow("Background", hex: draft.background)
                    optionalColorRow("Bold", hex: draft.bold, fallback: draft.wrappedValue.foreground)
                    colorRow("Cursor", hex: draft.cursor)
                    optionalColorRow("Cursor text", hex: draft.cursorText, fallback: draft.wrappedValue.background)
                    colorRow("Selection", hex: draft.selection)
                    optionalColorRow("Selected text", hex: draft.selectionText, fallback: draft.wrappedValue.foreground)
                    LabeledContent("Contrast") {
                        Text(String(format: "%.1f : 1", TerminalTheme.contrast(draft.wrappedValue.foreground, draft.wrappedValue.background)))
                            .foregroundStyle(TerminalTheme.contrast(draft.wrappedValue.foreground, draft.wrappedValue.background) < 4.5 ? .orange : .secondary)
                    }
                }
                Section("ANSI colours") {
                    ForEach(0..<8, id: \.self) { index in
                        HStack {
                            colorRow(Self.ansiNames[index], hex: draft.ansi[index])
                            colorRow("Bright", hex: draft.ansi[index + 8])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(selectedIsBuiltIn)
            .frame(minWidth: 380)

            VStack(spacing: 10) {
                ThemeSampleView(theme: draft.wrappedValue, appearance: themes.resolve(HostAppearance()))
                    .frame(minHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Use Everywhere") { themes.globalThemeID = draft.wrappedValue.id; themes.autoSwitch = .off; message = "Applied as the global scheme." }
                    if themes.autoSwitch != .off {
                        Button(draft.wrappedValue.isDark ? "Use as Dark" : "Use as Light") {
                            if draft.wrappedValue.isDark { themes.darkThemeID = draft.wrappedValue.id } else { themes.lightThemeID = draft.wrappedValue.id }
                            message = "Set as the \(draft.wrappedValue.isDark ? "dark" : "light") scheme."
                        }
                    }
                    Spacer()
                    Button("Duplicate") { duplicate() }
                    Button("Export JSON…") { exportJSON(draft.wrappedValue) }
                    if !selectedIsBuiltIn {
                        Button("Save") { save(draft.wrappedValue) }.keyboardShortcut("s", modifiers: .command)
                        Button("Delete", role: .destructive) { delete(draft.wrappedValue) }
                    }
                }
                .controlSize(.small)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text("Export writes a JSON file you can share on GitHub; others install it from a tepfasonic://theme?url=… link or by opening the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .frame(minWidth: 360)
        }
    }

    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    private func colorRow(_ title: String, hex: Binding<String>) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { HostColor.color(hex.wrappedValue) ?? .black },
                set: { hex.wrappedValue = Self.hex(from: $0) }), supportsOpacity: false)
            Text(hex.wrappedValue).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func optionalColorRow(_ title: String, hex: Binding<String?>, fallback: String) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { HostColor.color(hex.wrappedValue ?? fallback) ?? .black },
                set: { hex.wrappedValue = Self.hex(from: $0) }), supportsOpacity: false)
            if hex.wrappedValue != nil {
                Button("Default") { hex.wrappedValue = nil }.buttonStyle(.borderless).font(.caption)
            } else {
                Text("default").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    static func hex(from color: SwiftUI.Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return TerminalTheme.hex(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
    }

    private func duplicate() {
        guard let draft else { return }
        let copy = themes.save(draft.asUserTheme(named: draft.name + " copy"))
        selectedID = copy.id
    }

    private func save(_ theme: TerminalTheme) {
        themes.save(theme)
        message = "Saved."
    }

    private func delete(_ theme: TerminalTheme) {
        themes.delete(id: theme.id)
        selectedID = TerminalTheme.defaultDark.id
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a colour scheme"
        panel.message = "iTerm2 .itermcolors, Windows Terminal or VS Code JSON, Alacritty TOML/YAML, Ghostty config, or a Tepfasonic theme."
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var imported = 0
        for url in panel.urls {
            do {
                let theme = try themes.importTheme(from: url)
                selectedID = theme.id
                imported += 1
            } catch {
                message = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if imported > 0 { message = "Imported \(imported) scheme(s)." }
    }

    private func exportJSON(_ theme: TerminalTheme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = theme.name.replacingOccurrences(of: " ", with: "-").lowercased() + ".tepfasonic-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try themes.exportJSON(theme, to: url)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A read-only SwiftTerm view showing sample output in a scheme.
struct ThemeSampleView: NSViewRepresentable {
    let theme: TerminalTheme
    let appearance: TerminalAppearance

    static let sample: String = {
        var lines: [String] = []
        lines.append("\u{1b}[1;32muser@web-01\u{1b}[0m:\u{1b}[1;34m~/app\u{1b}[0m$ git status")
        lines.append("On branch \u{1b}[36mmain\u{1b}[0m")
        lines.append("\u{1b}[31mmodified:   src/server.ts\u{1b}[0m")
        lines.append("\u{1b}[32mnew file:   README.md\u{1b}[0m")
        lines.append("")
        var row = ""
        for index in 0..<8 { row += "\u{1b}[4\(index)m  \u{1b}[0m" }
        row += " "
        for index in 0..<8 { row += "\u{1b}[10\(index)m  \u{1b}[0m" }
        lines.append(row)
        lines.append("\u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m \u{1b}[33mwarning\u{1b}[0m \u{1b}[35m0x1F\u{1b}[0m https://example.com")
        lines.append("\u{1b}[1;32muser@web-01\u{1b}[0m:\u{1b}[1;34m~/app\u{1b}[0m$ ")
        return lines.joined(separator: "\r\n")
    }()

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var applied: TerminalAppearance?
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        var options = TerminalOptions.default
        options.scrollback = 50
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240), font: appearance.font(), options: options)
        view.terminalDelegate = context.coordinator
        view.allowMouseReporting = false
        apply(to: view, coordinator: context.coordinator)
        view.feed(text: Self.sample)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
    }

    private func apply(to view: TerminalView, coordinator: Coordinator) {
        var resolved = appearance
        resolved.theme = theme
        guard coordinator.applied != resolved else { return }
        coordinator.applied = resolved
        view.installColors(theme.ansi.map(TerminalAppearance.terminalColor))
        view.nativeForegroundColor = TerminalAppearance.nsColor(theme.foreground)
        view.nativeBackgroundColor = TerminalAppearance.nsColor(theme.background)
        view.caretColor = TerminalAppearance.nsColor(theme.cursor)
        view.caretTextColor = theme.cursorText.map(TerminalAppearance.nsColor)
        view.selectedTextBackgroundColor = TerminalAppearance.nsColor(theme.selection)
        view.font = resolved.font()
        view.setCursorStyle(resolved.swiftTermCursorStyle)
        view.minimumContrastRatio = CGFloat(resolved.minimumContrast)
    }
}

/// Confirms installing a scheme from a `tepfasonic://theme?url=` link.
struct ThemeInstallSheet: View {
    let pending: PendingThemeInstall
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss
    @State private var theme: TerminalTheme?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Install a colour scheme?", systemImage: "paintpalette")
                .font(.title3.weight(.semibold))
            Text("From \(pending.sourceURL.absoluteString)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if loading {
                ProgressView("Fetching…")
            } else if let theme {
                Text(theme.name).font(.headline)
                ThemeSampleView(theme: theme, appearance: themes.resolve(HostAppearance()))
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("The scheme is saved to your themes. It can be chosen globally, per group or per host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Install") {
                    if let theme {
                        themes.save(theme, source: "gallery")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(theme == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await fetch() }
    }

    private func fetch() async {
        defer { loading = false }
        guard ["https", "http", "file"].contains(pending.sourceURL.scheme?.lowercased() ?? "") else {
            error = "Only https links are accepted."
            return
        }
        do {
            let data: Data
            if pending.sourceURL.isFileURL {
                data = try Data(contentsOf: pending.sourceURL)
            } else {
                let (fetched, response) = try await URLSession.shared.data(from: pending.sourceURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    error = "The server did not return the scheme."
                    return
                }
                guard fetched.count < 512 * 1024 else {
                    error = "The file is too large to be a colour scheme."
                    return
                }
                data = fetched
            }
            theme = try ThemeImporter.theme(from: data, fileName: pending.sourceURL.lastPathComponent)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
