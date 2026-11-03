import AppKit
import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH

struct HostEditorView: View {
    let target: AppState.HostEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.name) private var groups: [HostGroup]
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query(sort: \Snippet.name) private var snippets: [Snippet]

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = NSUserName()
    @State private var authMethod: AuthMethod = .password
    @State private var groupID: UUID?
    @State private var identityID: UUID?
    @State private var tagsText = ""
    @State private var notes = ""
    @State private var colorLabel: String?
    @State private var autoReconnect = true
    @State private var defaultSnippetID: UUID?
    @State private var shellIntegration: ShellIntegrationMode = .automatic
    @State private var agentPermission: AgentPermissionMode = .ask
    @State private var agentAllowlistText = ""
    @State private var keyError: String?

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
            && (authMethod == .password || identityID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name, prompt: Text(hostname.isEmpty ? "Optional" : hostname))
                    TextField("Hostname", text: $hostname, prompt: Text("example.com or 10.0.0.5"))
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                }
                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    if authMethod == .privateKey {
                        Picker("Identity", selection: $identityID) {
                            Text("None").tag(UUID?.none)
                            ForEach(identities) { identity in
                                Text(identityLabel(identity)).tag(Optional(identity.uuid))
                            }
                        }
                        HStack {
                            Button("Choose Key File…") { chooseKeyFile() }
                            Button("Manage Identities…") { openWindow(id: IdentitiesView.windowID) }
                            Spacer()
                        }
                        if let identity = identities.first(where: { $0.uuid == identityID }) {
                            identitySummary(identity)
                        }
                        if let keyError {
                            Text(keyError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Text("An identity is a username plus a password, a key file or a key kept in the Keychain. Keys can be Ed25519, ECDSA or RSA in OpenSSH, PEM or PuTTY format; RSA keys cannot be used to connect yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You will be asked for the password when connecting, with the option to remember it in the Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Organisation") {
                    Picker("Group", selection: $groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(groups) { group in
                            Text(group.name).tag(Optional(group.uuid))
                        }
                    }
                    TextField("Tags", text: $tagsText, prompt: Text("comma, separated"))
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    LabeledContent("Colour label") {
                        HStack(spacing: 6) {
                            colorSwatch(nil)
                            ForEach(HostColor.presets) { preset in
                                colorSwatch(preset.hex)
                            }
                        }
                    }
                }
                Section("Behaviour") {
                    Toggle("Reconnect automatically after a dropped connection", isOn: $autoReconnect)
                    Picker("Run on connect", selection: $defaultSnippetID) {
                        Text("Nothing").tag(UUID?.none)
                        ForEach(snippets) { snippet in
                            Text(snippet.name).tag(Optional(snippet.uuid))
                        }
                    }
                    if let snippet = snippets.first(where: { $0.uuid == defaultSnippetID }) {
                        Text(snippet.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !snippet.variables.isEmpty {
                            Text("Variables use their defaults when the snippet runs at connect time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Shell integration", selection: $shellIntegration) {
                        ForEach(ShellIntegrationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("Shell integration records each command with its exit status and powers suggestions; it needs bash or zsh on the host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Claude agent") {
                    Picker("Permission", selection: $agentPermission) {
                        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text(agentPermission.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if agentPermission == .allowlist {
                        TextEditor(text: $agentAllowlistText)
                            .font(.body.monospaced())
                            .frame(minHeight: 60, maxHeight: 120)
                        Text("One pattern per line, matched against the whole command: * matches any text, ? one character, or write a regular expression as /pattern/. Examples: `systemctl restart nginx`, `docker logs *`, `/^git (pull|status)/`. Destructive commands always ask.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add Host") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
        .onAppear(perform: load)
    }

    private func identityLabel(_ identity: Identity) -> String {
        var label = identity.name
        if !identity.username.isEmpty { label += " (\(identity.username))" }
        return label + " · " + identity.credentialKind.displayName
    }

    @ViewBuilder
    private func identitySummary(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !identity.username.isEmpty {
                Text("Logs in as \(identity.username), overriding the username above.")
            }
            switch identity.credentialKind {
            case .password:
                Text("Password stored in the Keychain.")
            case .keyFile:
                Text(identity.privateKeyPath).font(.caption.monospaced()).textSelection(.enabled)
            case .keychainKey:
                Text("Private key stored in the Keychain.")
            }
            if let fingerprint = identity.fingerprint {
                Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func colorSwatch(_ hex: String?) -> some View {
        Button {
            colorLabel = hex
        } label: {
            ZStack {
                Circle()
                    .fill(HostColor.color(hex) ?? Color(nsColor: .controlBackgroundColor))
                    .frame(width: 18, height: 18)
                if hex == nil {
                    Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if colorLabel == hex {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "No colour" : (HostColor.presets.first { $0.hex == hex }?.name ?? hex!))
    }

    private func load() {
        if case .createFrom(let descriptor) = target {
            name = descriptor.name
            hostname = descriptor.hostname
            port = String(descriptor.port)
            username = descriptor.username
            authMethod = descriptor.authMethod
            return
        }
        guard case .edit(let host) = target else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        groupID = host.group?.uuid
        identityID = host.identity?.uuid
        tagsText = host.tags.joined(separator: ", ")
        notes = host.notes
        colorLabel = host.colorLabel
        autoReconnect = host.autoReconnect
        defaultSnippetID = host.defaultSnippet?.uuid
        shellIntegration = host.shellIntegration
        agentPermission = host.agentPermission
        agentAllowlistText = host.agentAllowlist.joined(separator: "\n")
    }

    private var agentAllowlist: [String] {
        agentAllowlistText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        guard let portNumber else { return }
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let group = groups.first { $0.uuid == groupID }
        let identity = authMethod == .privateKey ? identities.first { $0.uuid == identityID } : nil
        let defaultSnippet = snippets.first { $0.uuid == defaultSnippetID }

        switch target {
        case .create, .createFrom:
            let host = SSHHost(
                name: trimmedName.isEmpty ? trimmedHost : trimmedName,
                hostname: trimmedHost,
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespaces),
                authMethod: authMethod,
                tags: tags,
                notes: notes,
                colorLabel: colorLabel,
                autoReconnect: autoReconnect,
                group: group,
                identity: identity)
            host.defaultSnippet = defaultSnippet
            host.shellIntegration = shellIntegration
            host.agentPermission = agentPermission
            host.agentAllowlist = agentAllowlist
            modelContext.insert(host)
        case .edit(let host):
            host.name = trimmedName.isEmpty ? trimmedHost : trimmedName
            host.hostname = trimmedHost
            host.port = portNumber
            host.username = username.trimmingCharacters(in: .whitespaces)
            host.authMethod = authMethod
            host.tags = tags
            host.notes = notes
            host.group = group
            host.identity = identity
            host.colorLabel = colorLabel
            host.autoReconnect = autoReconnect
            host.defaultSnippet = defaultSnippet
            host.shellIntegration = shellIntegration
            host.agentPermission = agentPermission
            host.agentAllowlist = agentAllowlist
        }
        try? modelContext.save()
        dismiss()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a private key"
        panel.message = "Choose a private key in OpenSSH, PEM or PuTTY format."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let identity = try IdentityOperations.identityForKeyFile(at: url, existing: identities, in: modelContext)
            identityID = identity.uuid
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}
