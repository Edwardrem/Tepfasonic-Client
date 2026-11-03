import SwiftUI
import TepfaCore
import TepfaTerminal

/// Settings → Appearance: colour schemes and auto-switching, fonts, cursor and
/// text rendering, window appearance, badges.
struct AppearanceSettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.openWindow) private var openWindow
    @AppStorage(TerminalPreferences.fontNameKey) private var fontName: String?
    @AppStorage(TerminalPreferences.fontSizeKey) private var fontSize = 13.0
    @AppStorage(TerminalPreferences.lineHeightKey) private var lineHeight = 1.0
    @AppStorage(TerminalPreferences.letterSpacingKey) private var letterSpacing = 0.0
    @AppStorage(TerminalPreferences.ligaturesKey) private var ligatures = true
    @AppStorage(TerminalPreferences.boldFontKey) private var boldFont = true
    @AppStorage(TerminalPreferences.italicFontKey) private var italicFont = true
    @AppStorage(TerminalPreferences.cursorStyleKey) private var cursorStyle = "block"
    @AppStorage(TerminalPreferences.cursorBlinkKey) private var cursorBlink = true
    @AppStorage(TerminalPreferences.antialiasKey) private var antialias = true
    @AppStorage(TerminalPreferences.minimumContrastKey) private var minimumContrast = 1.0
    @AppStorage(TerminalPreferences.backgroundOpacityKey) private var backgroundOpacity = 1.0
    @AppStorage(TerminalPreferences.backgroundBlurKey) private var backgroundBlur = true
    @AppStorage(TerminalPreferences.linkModifierKey) private var linkNeedsModifier = true
    @AppStorage(TerminalPreferences.badgeEnabledKey) private var badgeEnabled = false
    @AppStorage(TerminalPreferences.badgePositionKey) private var badgePosition = "topRight"
    @AppStorage(TerminalPreferences.badgeColorKey) private var badgeColor = ""
    @AppStorage(TerminalPreferences.badgeShowsUserKey) private var badgeShowsUser = true
    @AppStorage(TerminalPreferences.badgeShowsUptimeKey) private var badgeShowsUptime = true
    @AppStorage("ui.showTabBar") private var showTabBar = true
    @AppStorage("ui.showStatusBar") private var showStatusBar = true
    @AppStorage("ui.showColorStripes") private var showColorStripes = true

    var body: some View {
        @Bindable var themes = themes
        Form {
            Section("Colour scheme") {
                Picker("Mode", selection: $themes.autoSwitch) {
                    ForEach(ThemeStore.AutoSwitch.allCases) { Text($0.displayName).tag($0) }
                }
                switch themes.autoSwitch {
                case .off:
                    themePicker("Scheme", selection: $themes.globalThemeID)
                case .system:
                    themePicker("Light scheme", selection: $themes.lightThemeID)
                    themePicker("Dark scheme", selection: $themes.darkThemeID)
                case .schedule:
                    themePicker("Light scheme", selection: $themes.lightThemeID)
                    themePicker("Dark scheme", selection: $themes.darkThemeID)
                    minutePicker("Light from", selection: $themes.scheduleLightStart)
                    minutePicker("Dark from", selection: $themes.scheduleDarkStart)
                }
                ThemeSampleView(theme: themes.globalTheme, appearance: themes.resolve(HostAppearance()))
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Theme Editor…") { openWindow(id: ThemeEditorView.windowID) }
                    Text("Edit, import (iTerm2, Windows Terminal, VS Code, Alacritty, Ghostty) and export schemes. Groups and hosts can override the scheme and font.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Font") {
                Picker("Family", selection: $fontName) {
                    Text("JetBrains Mono (bundled)").tag(String?.none)
                    ForEach(FontCatalog.monospaceFamilies().filter { $0 != TerminalPreferences.defaultFontName }, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                Slider(value: $fontSize, in: 8...28, step: 1) {
                    Text("Size: \(Int(fontSize)) pt")
                }
                Slider(value: $lineHeight, in: 0.9...1.6, step: 0.05) {
                    Text(String(format: "Line height: %.2f", lineHeight))
                }
                Slider(value: $letterSpacing, in: -1...3, step: 0.5) {
                    Text(String(format: "Letter spacing: %.1f", letterSpacing))
                }
                Toggle("Ligatures", isOn: $ligatures)
                Toggle("Use the bold face for bold text", isOn: $boldFont)
                Toggle("Use the italic face for italic text", isOn: $italicFont)
                Text("Letter spacing is kept for fonts that honour it; the terminal engine does not currently stretch glyph cells.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cursor and text") {
                Picker("Cursor", selection: $cursorStyle) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                Toggle("Blink", isOn: $cursorBlink)
                Toggle("Anti-alias text", isOn: $antialias)
                Slider(value: $minimumContrast, in: 1...7, step: 0.5) {
                    Text(minimumContrast <= 1 ? "Minimum contrast: off" : String(format: "Minimum contrast: %.1f : 1", minimumContrast))
                }
                Text("Raises text colours that would vanish against the background, such as dark blue on black.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $backgroundOpacity, in: 0.3...1, step: 0.05) {
                    Text("Background opacity: \(Int(backgroundOpacity * 100))%")
                }
                Toggle("Blur what is behind a translucent terminal", isOn: $backgroundBlur)
                    .disabled(backgroundOpacity >= 1)
                Toggle("Hold ⌘ to open links and paths", isOn: $linkNeedsModifier)
            }
            Section("Badge") {
                Toggle("Show a badge in the terminal corner", isOn: $badgeEnabled)
                Picker("Position", selection: $badgePosition) {
                    Text("Top right").tag("topRight")
                    Text("Top left").tag("topLeft")
                    Text("Bottom right").tag("bottomRight")
                    Text("Bottom left").tag("bottomLeft")
                }
                .disabled(!badgeEnabled)
                LabeledContent("Colour") {
                    ColorLabelPicker(selection: Binding(get: { badgeColor.isEmpty ? nil : badgeColor }, set: { badgeColor = $0 ?? "" }))
                }
                .disabled(!badgeEnabled)
                Toggle("Show user and hostname", isOn: $badgeShowsUser).disabled(!badgeEnabled)
                Toggle("Show session uptime", isOn: $badgeShowsUptime).disabled(!badgeEnabled)
            }
            Section("App") {
                Picker("Appearance", selection: Binding(get: { themes.appearance.app }, set: { themes.setAppAppearance($0) })) {
                    ForEach(ThemeStore.AppAppearance.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Accent colour") {
                    HStack(spacing: 6) {
                        ColorLabelPicker(selection: Binding(get: { themes.appearance.accent }, set: { themes.setAccent($0) }))
                        Text(themes.appearance.accent == nil ? "system" : "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Sidebar density", selection: Binding(get: { themes.appearance.compactSidebar }, set: { themes.setCompactSidebar($0) })) {
                    Text("Comfortable").tag(false)
                    Text("Compact").tag(true)
                }
                Toggle("Show tab bar", isOn: $showTabBar)
                Toggle("Show status bar", isOn: $showStatusBar)
                Toggle("Show host colour stripes on terminals and tabs", isOn: $showColorStripes)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom)
    }

    private func themePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Section("Bundled") {
                ForEach(TerminalTheme.bundled) { Text($0.name).tag($0.id) }
            }
            if !themes.userThemes.isEmpty {
                Section("Mine") {
                    ForEach(themes.userThemes) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    private func minutePicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { minutes in
                Text(String(format: "%02d:%02d", minutes / 60, minutes % 60)).tag(minutes)
            }
        }
    }
}
