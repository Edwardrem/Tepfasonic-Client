import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

/// Creates a group, or edits its name, colour and the defaults hosts inherit
/// (identity, jump host, proxy, theme and font).
struct GroupEditorView: View {
    let group: HostGroup?
    /// Hosts to put in a new group as soon as it exists (from "Move to Group → New Group…").
    var addingHostIDs: [UUID] = []
    /// Called with the group after it is created, for pickers that want to select it.
    var onCreate: ((HostGroup) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeStore.self) private var themes
    @Query private var groups: [HostGroup]
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]

    @State private var name = ""
    @State private var colorLabel: String?
    @State private var defaultIdentityID: UUID?
    @State private var defaultJumpHostID: UUID?
    @State private var proxy = ProxyFields()
    @State private var themeID: String?
    @State private var fontName: String?
    @State private var fontSize: Double?
    @State private var memberIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(group == nil ? "New Group" : "Group") {
                    TextField("Name", text: $name, prompt: Text("Production, Home lab, …"))
                    LabeledContent("Colour label") {
                        ColorLabelPicker(selection: $colorLabel)
                    }
                }
                Section {
                    if hosts.isEmpty {
                        Text("No hosts yet. Add hosts with ⌘N; they can join a group from the host editor, the sidebar menu or by dragging.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hosts) { host in
                        Toggle(isOn: membership(host)) {
                            HStack(spacing: 8) {
                                IconTile(systemImage: "server.rack", color: HostColor.color(host.colorLabel ?? host.group?.colorLabel) ?? HostRow.neutralTile, size: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(host.name)
                                    Text(host.displayTarget).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let other = host.group, other.uuid != group?.uuid, !memberIDs.contains(host.uuid) {
                                    Text(other.name).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("Hosts in this group")
                } footer: {
                    if !hosts.isEmpty {
                        Text(memberIDs.isEmpty ? "Tick the hosts that belong here. A host can be in one group at a time." : "\(memberIDs.count) of \(hosts.count) hosts. A host can be in one group at a time.")
                    }
                }
                Section("Defaults for hosts in this group") {
                    Picker("Identity", selection: $defaultIdentityID) {
                        Text("None").tag(UUID?.none)
                        ForEach(identities) { identity in
                            Text(identity.name + (identity.username.isEmpty ? "" : " (\(identity.username))")).tag(Optional(identity.uuid))
                        }
                    }
                    Picker("Jump host", selection: $defaultJumpHostID) {
                        Text("None").tag(UUID?.none)
                        ForEach(hosts) { host in
                            Text(host.name).tag(Optional(host.uuid))
                        }
                    }
                    Text("Hosts use these unless they set their own. A host with a jump host of its own, or with inheritance turned off, keeps its setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProxySection(fields: $proxy, ownerID: group?.uuid)
                AppearanceSection(themeID: $themeID, fontName: $fontName, fontSize: $fontSize, inheritedLabel: "Global setting")
            }
            .formStyle(.grouped)
            .themedForm()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(group == nil ? "Add Group" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: load)
    }

    private func membership(_ host: SSHHost) -> Binding<Bool> {
        Binding(
            get: { memberIDs.contains(host.uuid) },
            set: { isMember in
                if isMember { memberIDs.insert(host.uuid) } else { memberIDs.remove(host.uuid) }
            })
    }

    private func load() {
        memberIDs = Set(addingHostIDs)
        guard let group else { return }
        memberIDs.formUnion(hosts.filter { $0.group?.uuid == group.uuid }.map(\.uuid))
        name = group.name
        colorLabel = group.colorLabel
        defaultIdentityID = group.defaultIdentity?.uuid
        defaultJumpHostID = group.defaultJumpHost?.uuid
        proxy = ProxyFields(kind: group.proxyKindRaw, host: group.proxyHost, port: group.proxyPort, username: group.proxyUsername)
        themeID = group.themeID
        fontName = group.fontName
        fontSize = group.fontSize
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let isNew = group == nil
        let target = group ?? {
            let created = HostGroup(name: trimmed, sortOrder: HostGrouping.nextSortOrder(after: groups))
            modelContext.insert(created)
            return created
        }()
        target.name = trimmed
        target.colorLabel = colorLabel
        target.defaultIdentity = identities.first { $0.uuid == defaultIdentityID }
        target.defaultJumpHost = hosts.first { $0.uuid == defaultJumpHostID }
        proxy.apply(kind: &target.proxyKindRaw, host: &target.proxyHost, port: &target.proxyPort, username: &target.proxyUsername, ownerID: target.uuid)
        target.themeID = themeID
        target.fontName = fontName
        target.fontSize = fontSize
        let joining = hosts.filter { memberIDs.contains($0.uuid) && $0.group?.uuid != target.uuid }
        let leaving = hosts.filter { !memberIDs.contains($0.uuid) && $0.group?.uuid == target.uuid }
        if !joining.isEmpty { HostGrouping.move(joining, to: target, among: hosts) }
        if !leaving.isEmpty { HostGrouping.move(leaving, to: nil, among: hosts) }
        try? modelContext.save()
        if isNew { onCreate?(target) }
        dismiss()
    }
}

/// The preset colour swatches shared by the host and group editors.
struct ColorLabelPicker: View {
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 6) {
            swatch(nil)
            ForEach(HostColor.presets) { preset in
                swatch(preset.hex)
            }
        }
    }

    private func swatch(_ hex: String?) -> some View {
        Button {
            selection = hex
        } label: {
            ZStack {
                Circle()
                    .fill(HostColor.color(hex) ?? Color(nsColor: .controlBackgroundColor))
                    .frame(width: 18, height: 18)
                if hex == nil {
                    Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if selection == hex {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "No colour" : (HostColor.presets.first { $0.hex == hex }?.name ?? hex!))
    }
}

/// Editable proxy settings; the password goes to the Keychain under the owner's id.
struct ProxyFields: Equatable {
    var enabled = false
    var kind: ProxySettings.Kind = .http
    var host = ""
    var port = ""
    var username = ""
    var password = ""
    var clearPassword = false

    init() {}

    init(kind: String?, host: String, port: Int, username: String) {
        enabled = kind != nil && !host.isEmpty
        self.kind = ProxySettings.Kind(rawValue: kind ?? "") ?? .http
        self.host = host
        self.port = port == 0 ? "" : String(port)
        self.username = username
    }

    var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }

    var isValid: Bool {
        !enabled || (!host.trimmingCharacters(in: .whitespaces).isEmpty && portNumber != nil)
    }

    /// Writes the fields to a host or group and stores or removes the password.
    @MainActor
    func apply(kind: inout String?, host: inout String, port: inout Int, username: inout String, ownerID: UUID) {
        if enabled, let portNumber {
            kind = self.kind.rawValue
            host = self.host.trimmingCharacters(in: .whitespaces)
            port = portNumber
            username = self.username.trimmingCharacters(in: .whitespaces)
            if !password.isEmpty {
                try? KeychainCredentialStore.shared.rememberProxyPassword(password, ownerID: ownerID)
            } else if clearPassword || username.isEmpty {
                KeychainCredentialStore.shared.forgetProxyPassword(ownerID: ownerID)
            }
        } else {
            kind = nil
            host = ""
            port = 0
            username = ""
            KeychainCredentialStore.shared.forgetProxyPassword(ownerID: ownerID)
        }
    }
}

struct ProxySection: View {
    @Binding var fields: ProxyFields
    /// The host or group the password belongs to (nil while creating).
    let ownerID: UUID?
    var inheritToggle: Binding<Bool>?

    private var hasSavedPassword: Bool {
        guard let ownerID else { return false }
        return KeychainCredentialStore.shared.hasProxyPassword(ownerID: ownerID)
    }

    var body: some View {
        Section("Proxy") {
            if let inheritToggle {
                Toggle("Use the group's proxy when none is set here", isOn: inheritToggle)
            }
            Toggle("Connect through a proxy", isOn: $fields.enabled)
            if fields.enabled {
                Picker("Type", selection: $fields.kind) {
                    ForEach(ProxySettings.Kind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("Proxy host", text: $fields.host, prompt: Text("proxy.example.com"))
                TextField("Proxy port", text: $fields.port, prompt: Text(fields.kind == .http ? "3128" : "1080"))
                TextField("Username", text: $fields.username, prompt: Text("Optional"))
                SecureField("Password", text: $fields.password, prompt: Text(hasSavedPassword && !fields.clearPassword ? "Saved in the Keychain" : "Optional"))
                if hasSavedPassword, fields.password.isEmpty {
                    Toggle("Remove the saved password", isOn: $fields.clearPassword)
                }
                Text("The TCP connection to the host goes through the proxy (HTTP CONNECT or SOCKS5). The SSH session itself stays end-to-end encrypted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Theme and font overrides shared by the host and group editors.
struct AppearanceSection: View {
    @Binding var themeID: String?
    @Binding var fontName: String?
    @Binding var fontSize: Double?
    let inheritedLabel: String
    @Environment(ThemeStore.self) private var themes

    private var fontChoices: [String] {
        var names = FontCatalog.monospaceFamilies()
        if let fontName, !names.contains(fontName) { names.insert(fontName, at: 0) }
        return names
    }

    var body: some View {
        Section("Appearance") {
            Picker("Colour scheme", selection: $themeID) {
                Text(inheritedLabel).tag(String?.none)
                Section("Bundled") {
                    ForEach(TerminalTheme.bundled) { theme in
                        Text(theme.name).tag(Optional(theme.id))
                    }
                }
                if !themes.userThemes.isEmpty {
                    Section("Mine") {
                        ForEach(themes.userThemes) { theme in
                            Text(theme.name).tag(Optional(theme.id))
                        }
                    }
                }
            }
            if let themeID, let theme = themes.theme(id: themeID) {
                ThemeSwatchRow(theme: theme)
            }
            Picker("Font", selection: $fontName) {
                Text(inheritedLabel).tag(String?.none)
                ForEach(fontChoices, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            Picker("Font size", selection: $fontSize) {
                Text(inheritedLabel).tag(Double?.none)
                ForEach([9.0, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24], id: \.self) { size in
                    Text("\(Int(size)) pt").tag(Optional(size))
                }
            }
        }
    }
}

/// A one-line preview of a scheme's colours.
struct ThemeSwatchRow: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, hex in
                RoundedRectangle(cornerRadius: 2).fill(HostColor.color(hex) ?? .clear).frame(width: 14, height: 14)
            }
            Spacer()
            Text(theme.isDark ? "Dark" : "Light").font(.caption).foregroundStyle(.secondary)
        }
        .padding(4)
        .background(HostColor.color(theme.background) ?? .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}
