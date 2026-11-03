import AppKit
import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

struct HostEditorView: View {
    let target: AppState.HostEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.name) private var groups: [HostGroup]
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query(sort: \Snippet.name) private var snippets: [Snippet]
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var allHosts: [SSHHost]

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
    @State private var jumpHostID: UUID?
    @State private var inheritsGroupJumpHost = true
    @State private var proxy = ProxyFields()
    @State private var inheritsGroupProxy = true
    @State private var themeID: String?
    @State private var fontName: String?
    @State private var fontSize: Double?
    @State private var backgroundTint: String?
    @State private var watermark = ""

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }

    private var editedHostID: UUID? {
        if case .edit(let host) = target { return host.uuid }
        return nil
    }

    private var selectedGroup: HostGroup? {
        groups.first { $0.uuid == groupID }
    }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
            && (authMethod == .password || identityID != nil || selectedGroup?.defaultIdentity != nil)
            && proxy.isValid
            && jumpHostID != editedHostID
    }

    /// Hosts that may serve as a jump host: not this one, and not one that already jumps through it.
    private var jumpCandidates: [SSHHost] {
        allHosts.filter { candidate in
            guard candidate.uuid != editedHostID else { return false }
            var current: SSHHost? = candidate
            var seen = 0
            while let host = current, seen < HostDescriptor.maximumJumpDepth {
                if host.effectiveJumpHost?.uuid == editedHostID { return false }
                current = host.effectiveJumpHost
                seen += 1
            }
            return true
        }
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
                        } else if let inherited = selectedGroup?.defaultIdentity {
                            Text("None chosen: the group's default identity \(inherited.name) will be used.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        ColorLabelPicker(selection: $colorLabel)
                    }
                }
                Section("Route") {
                    Picker("Jump host", selection: $jumpHostID) {
                        Text(selectedGroup?.defaultJumpHost != nil && inheritsGroupJumpHost ? "Group default (\(selectedGroup?.defaultJumpHost?.name ?? ""))" : "None (connect directly)").tag(UUID?.none)
                        ForEach(jumpCandidates) { host in
                            Text(host.name + (host.effectiveJumpHost.map { " (via \($0.name))" } ?? "")).tag(Optional(host.uuid))
                        }
                    }
                    if selectedGroup?.defaultJumpHost != nil {
                        Toggle("Use the group's jump host when none is set here", isOn: $inheritsGroupJumpHost)
                    }
                    Text("The connection is multiplexed through the bastion's SSH connection (a direct-tcpip channel, never a shell), and bastions can chain: each jump host's own jump host is used first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProxySection(fields: $proxy, ownerID: editedHostID, inheritToggle: selectedGroup?.proxy != nil ? $inheritsGroupProxy : nil)
                AppearanceSection(themeID: $themeID, fontName: $fontName, fontSize: $fontSize, inheritedLabel: selectedGroup != nil ? "Group setting" : "Global setting")
                Section("Warnings") {
                    LabeledContent("Background tint") {
                        ColorLabelPicker(selection: $backgroundTint)
                    }
                    TextField("Watermark", text: $watermark, prompt: Text("PROD"))
                    Text("A tint washes the terminal background with the colour; a watermark draws the text faintly across it. Both make a production box unmistakable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .edit(let host) = target {
                    Section("Port forwarding") {
                        if host.portForwards.isEmpty {
                            Text("No rules yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(host.portForwards.sorted { $0.sortOrder < $1.sortOrder }) { rule in
                                Text(rule.displayName + (rule.autoStart ? " · starts on connect" : ""))
                            }
                        }
                        Text("Rules are managed in the Port Forwarding sidebar (⌘⇧P).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .frame(width: 520, height: 680)
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
        jumpHostID = host.jumpHost?.uuid
        inheritsGroupJumpHost = host.inheritsGroupJumpHost
        proxy = ProxyFields(kind: host.proxyKindRaw, host: host.proxyHost, port: host.proxyPort, username: host.proxyUsername)
        inheritsGroupProxy = host.inheritsGroupProxy
        themeID = host.themeID
        fontName = host.fontName
        fontSize = host.fontSize
        backgroundTint = host.backgroundTint
        watermark = host.watermark ?? ""
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
            applyExtras(to: host)
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
            applyExtras(to: host)
        }
        try? modelContext.save()
        dismiss()
    }

    private func applyExtras(to host: SSHHost) {
        host.jumpHost = allHosts.first { $0.uuid == jumpHostID && $0.uuid != host.uuid }
        host.inheritsGroupJumpHost = inheritsGroupJumpHost
        proxy.apply(kind: &host.proxyKindRaw, host: &host.proxyHost, port: &host.proxyPort, username: &host.proxyUsername, ownerID: host.uuid)
        host.inheritsGroupProxy = inheritsGroupProxy
        host.themeID = themeID
        host.fontName = fontName
        host.fontSize = fontSize
        host.backgroundTint = backgroundTint
        let mark = watermark.trimmingCharacters(in: .whitespaces)
        host.watermark = mark.isEmpty ? nil : mark
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
