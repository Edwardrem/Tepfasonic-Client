import SwiftUI
import TepfaTerminal

struct SettingsView: View {
    @State private var tab = SettingsView.initialTab

    /// Debug builds take `--settings-tab=<name>` (general, appearance, security, known-hosts, data,
    /// claude, cloud, updates) so a UI check can open Settings on one pane.
    private static var initialTab: String {
        #if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--settings-tab=") }) {
            return String(argument.dropFirst("--settings-tab=".count))
        }
        #endif
        return "general"
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag("appearance")
            SecuritySettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag("security")
            KnownHostsSettingsView()
                .tabItem { Label("Known Hosts", systemImage: "checkmark.shield") }
                .tag("known-hosts")
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag("data")
            ClaudeSettingsView()
                .tabItem { Label("Claude", systemImage: "sparkles") }
                .tag("claude")
            CloudSettingsView()
                .tabItem { Label("Cloud", systemImage: "cloud") }
                .tag("cloud")
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag("updates")
        }
        .frame(width: 620)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(TerminalPreferences.copyOnSelectKey) private var copyOnSelect = false
    @AppStorage(TerminalPreferences.warnOnMultiLinePasteKey) private var warnOnMultiLinePaste = true
    @AppStorage(TerminalPreferences.scrollbackKey) private var scrollback = 100_000
    @AppStorage(TerminalPreferences.shellIntegrationKey) private var shellIntegration = true
    @AppStorage(TerminalPreferences.recordHistoryKey) private var recordHistory = true
    @AppStorage(TerminalPreferences.suggestionsKey) private var suggestions = true
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Terminal") {
                Toggle("Copy selected text to the clipboard automatically", isOn: $copyOnSelect)
                Toggle("Warn before pasting several lines", isOn: $warnOnMultiLinePaste)
                Picker("Scrollback", selection: $scrollback) {
                    Text("10 000 lines").tag(10_000)
                    Text("100 000 lines").tag(100_000)
                    Text("1 000 000 lines").tag(1_000_000)
                }
                Text("Scrollback applies to terminals opened after the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shell") {
                Toggle("Set up shell integration on bash and zsh hosts", isOn: $shellIntegration)
                Text("Sends a one-line setup after connecting so the terminal knows where each prompt, command and its exit status begins. Nothing is written to the host. Hosts can override this in their settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Record commands run in every session", isOn: $recordHistory)
                Toggle("Suggest commands from history and snippets while typing", isOn: $suggestions)
                Text("Suggestions appear under the cursor: → accepts, ⌥↑ and ⌥↓ choose, Esc hides. Text typed without echo, such as passwords, is never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear History…") { confirmingClear = true }
                    .confirmationDialog("Clear the command history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear History", role: .destructive) { HistoryOperations.clearAll() }
                    }
            }
            Section("Layout") {
                Text("Tab bar, status bar, colour stripes, fonts and colour schemes are in Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.bottom)
    }
}

struct UpdatesSettingsView: View {
    @Environment(UpdateManager.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section("Updates") {
                LabeledContent("Version", value: "\(UpdateManager.currentShortVersion) (\(UpdateManager.currentVersion))")
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticChecks },
                    set: { updates.automaticChecks = $0 }))
                Toggle("Include beta releases", isOn: Binding(
                    get: { updates.betaChannel },
                    set: { updates.betaChannel = $0 }))
                HStack {
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(updates.isChecking)
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    if let lastCheck = updates.lastCheck {
                        Text("Last checked \(lastCheck.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = updates.noUpdateMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let error = updates.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if case .downloadOnly(let reason) = updates.mode, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let feed = updates.feedURL {
                    LabeledContent("Feed") {
                        Text(feed.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.bottom)
        .sheet(item: $updates.availableUpdate) { item in
            UpdateAvailableView(item: item)
        }
    }
}
