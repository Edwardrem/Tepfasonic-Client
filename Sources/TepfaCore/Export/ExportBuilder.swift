import Foundation
import SwiftData

/// Builds a `TepfaDocument` from the app's data.
@MainActor
public enum ExportBuilder {
    public struct Options: Sendable, Equatable {
        public var hosts = true
        public var identities = true
        public var snippets = true
        public var knownHosts = true
        public var portForwards = true
        public var themes = true
        public var serialProfiles = true
        /// Passwords, Keychain keys and passphrases. Requires an encrypted file.
        public var secrets = false

        public init(hosts: Bool = true, identities: Bool = true, snippets: Bool = true, knownHosts: Bool = true, portForwards: Bool = true, themes: Bool = true, serialProfiles: Bool = true, secrets: Bool = false) {
            self.hosts = hosts
            self.identities = identities
            self.snippets = snippets
            self.knownHosts = knownHosts
            self.portForwards = portForwards
            self.themes = themes
            self.serialProfiles = serialProfiles
            self.secrets = secrets
        }
    }

    /// `secrets` is asked for each identity when `options.secrets` is on; it
    /// may prompt to unlock the vault, so it is async. `proxyPassword` is asked
    /// for each host or group that has a proxy with a username.
    public static func document(
        from context: ModelContext,
        knownHosts: [KnownHostEntry],
        options: Options,
        appVersion: String? = nil,
        secrets: (@MainActor (Identity) async throws -> TepfaDocument.IdentitySecrets?)? = nil,
        proxyPassword: (@MainActor (UUID) async throws -> String?)? = nil
    ) async throws -> TepfaDocument {
        var document = TepfaDocument(exportedAt: .now, appVersion: appVersion)
        if options.hosts {
            let groups = try context.fetch(FetchDescriptor<HostGroup>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
            document.groups = groups.map(TepfaDocument.GroupRecord.init)
            let hosts = try context.fetch(FetchDescriptor<SSHHost>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
            document.hosts = hosts.map(TepfaDocument.HostRecord.init)
            if options.secrets, let proxyPassword {
                var passwords: [String: String] = [:]
                for host in hosts where host.ownProxy?.username != nil {
                    if let password = try await proxyPassword(host.uuid) { passwords[host.uuid.uuidString] = password }
                }
                for group in groups where group.proxy?.username != nil {
                    if let password = try await proxyPassword(group.uuid) { passwords[group.uuid.uuidString] = password }
                }
                if !passwords.isEmpty {
                    var record = document.secrets ?? TepfaDocument.SecretsRecord()
                    record.proxyPasswords = passwords
                    document.secrets = record
                }
            }
            if options.portForwards {
                let rules = try context.fetch(FetchDescriptor<PortForwardRule>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))
                document.portForwards = rules.compactMap(TepfaDocument.PortForwardRecord.init)
            }
        }
        if options.themes {
            let themes = try context.fetch(FetchDescriptor<TerminalThemeRecord>(sortBy: [SortDescriptor(\.name)]))
            document.themes = themes.compactMap(TepfaDocument.ThemeRecord.init)
        }
        if options.serialProfiles {
            let profiles = try context.fetch(FetchDescriptor<SerialProfile>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
            document.serialProfiles = profiles.map(TepfaDocument.SerialProfileRecord.init)
        }
        if options.identities {
            let identities = try context.fetch(FetchDescriptor<Identity>(sortBy: [SortDescriptor(\.name)]))
            document.identities = identities.map(TepfaDocument.IdentityRecord.init)
            if options.secrets, let secrets {
                var record = document.secrets ?? TepfaDocument.SecretsRecord()
                for identity in identities {
                    if let value = try await secrets(identity), !value.isEmpty {
                        record.identities[identity.uuid.uuidString] = value
                    }
                }
                document.secrets = record.isEmpty ? nil : record
            }
        } else if options.hosts {
            // Hosts that reference identities keep the reference; the identity itself is not exported.
        }
        if options.snippets {
            let folders = try context.fetch(FetchDescriptor<SnippetFolder>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
            document.snippetFolders = folders.map(TepfaDocument.SnippetFolderRecord.init)
            let snippets = try context.fetch(FetchDescriptor<Snippet>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
            document.snippets = snippets.map(TepfaDocument.SnippetRecord.init)
        } else {
            for index in document.hosts.indices { document.hosts[index].defaultSnippetID = nil }
        }
        if options.knownHosts {
            document.knownHosts = knownHosts
                .sorted { ($0.host, $0.port, $0.keyType) < ($1.host, $1.port, $1.keyType) }
                .map(TepfaDocument.KnownHostRecord.init)
        }
        return document
    }
}

public extension TepfaDocument.GroupRecord {
    @MainActor init(_ group: HostGroup) {
        self.init(
            id: group.uuid, name: group.name, sortOrder: group.sortOrder, colorLabel: group.colorLabel,
            defaultIdentityID: group.defaultIdentity?.uuid, defaultJumpHostID: group.defaultJumpHost?.uuid,
            proxy: group.proxy.map(TepfaDocument.ProxyRecord.init), themeID: group.themeID, fontName: group.fontName, fontSize: group.fontSize)
    }
}

public extension TepfaDocument.ProxyRecord {
    init(_ proxy: HostProxyConfiguration) {
        self.init(kind: proxy.kind, host: proxy.host, port: proxy.port, username: proxy.username)
    }
}

public extension TepfaDocument.PortForwardRecord {
    /// Nil for a rule that lost its host.
    @MainActor init?(_ rule: PortForwardRule) {
        guard let host = rule.host else { return nil }
        self.init(
            id: rule.uuid, hostID: host.uuid, kind: rule.kindRaw, bindAddress: rule.bindAddress, bindPort: rule.bindPort,
            targetHost: rule.targetHost, targetPort: rule.targetPort, autoStart: rule.autoStart, name: rule.name, sortOrder: rule.sortOrder)
    }
}

public extension TepfaDocument.ThemeRecord {
    /// Nil when the stored JSON no longer decodes.
    @MainActor init?(_ record: TerminalThemeRecord) {
        guard var scheme = try? TerminalTheme.decode(record.schemeJSON) else { return nil }
        scheme.id = record.uuid.uuidString
        scheme.name = record.name
        self.init(id: record.uuid, name: record.name, source: record.source, scheme: scheme)
    }
}

public extension TepfaDocument.SerialProfileRecord {
    @MainActor init(_ profile: SerialProfile) {
        self.init(
            id: profile.uuid, name: profile.name, devicePath: profile.devicePath, baudRate: profile.baudRate, dataBits: profile.dataBits,
            parity: profile.parityRaw, stopBits: profile.stopBits, flowControl: profile.flowControlRaw, sendLineEnding: profile.sendLineEndingRaw,
            convertIncomingLF: profile.convertIncomingLF, localEcho: profile.localEcho, hexView: profile.hexView, colorLabel: profile.colorLabel, sortOrder: profile.sortOrder)
    }
}

public extension TepfaDocument.HostRecord {
    @MainActor init(_ host: SSHHost) {
        self.init(
            id: host.uuid, name: host.name, hostname: host.hostname, port: host.port, username: host.username,
            authMethod: host.authMethodRaw, tags: host.tags, notes: host.notes, sortOrder: host.sortOrder,
            colorLabel: host.colorLabel, autoReconnect: host.autoReconnect, groupID: host.group?.uuid,
            identityID: host.identity?.uuid, defaultSnippetID: host.defaultSnippet?.uuid, shellIntegration: host.shellIntegrationRaw,
            agentPermission: host.agentPermissionRaw, agentAllowlist: host.agentAllowlist,
            jumpHostID: host.jumpHost?.uuid, inheritsGroupJumpHost: host.inheritsGroupJumpHost,
            proxy: host.ownProxy.map(TepfaDocument.ProxyRecord.init), inheritsGroupProxy: host.inheritsGroupProxy,
            themeID: host.themeID, fontName: host.fontName, fontSize: host.fontSize, backgroundTint: host.backgroundTint, watermark: host.watermark)
    }
}

public extension TepfaDocument.IdentityRecord {
    @MainActor init(_ identity: Identity) {
        self.init(
            id: identity.uuid, name: identity.name, username: identity.username, credentialKind: identity.credentialKindRaw,
            privateKeyPath: identity.privateKeyPath, publicKey: identity.publicKey, keyType: identity.keyType, fingerprint: identity.fingerprint)
    }
}

public extension TepfaDocument.SnippetFolderRecord {
    @MainActor init(_ folder: SnippetFolder) {
        self.init(id: folder.uuid, name: folder.name, sortOrder: folder.sortOrder)
    }
}

public extension TepfaDocument.SnippetRecord {
    @MainActor init(_ snippet: Snippet) {
        self.init(id: snippet.uuid, name: snippet.name, command: snippet.command, tags: snippet.tags, notes: snippet.notes, sortOrder: snippet.sortOrder, folderID: snippet.folder?.uuid)
    }
}
