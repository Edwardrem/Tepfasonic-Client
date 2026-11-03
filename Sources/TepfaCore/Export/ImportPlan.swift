import Foundation
import SwiftData

/// Compares a document with the current data and applies the user's choices:
/// new records are added, changed ones replaced or skipped, identical ones ignored.
@MainActor
public struct ImportPlan {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case group, identity, snippetFolder, snippet, host, portForward, theme, serialProfile, knownHost

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .group: "Groups"
            case .identity: "Identities"
            case .snippetFolder: "Snippet folders"
            case .snippet: "Snippets"
            case .host: "Hosts"
            case .portForward: "Port forwarding"
            case .theme: "Themes"
            case .serialProfile: "Serial profiles"
            case .knownHost: "Known hosts"
            }
        }
    }

    public enum Status: Sendable, Equatable {
        case new, changed, identical
    }

    public enum Action: Sendable, Equatable {
        case add, replace, skip
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let kind: Kind
        public let recordID: String
        public let title: String
        public let subtitle: String
        public let status: Status
        public var action: Action
        /// Field names that differ, for changed records.
        public let changes: [String]

        public var isImported: Bool { action != .skip }
    }

    public struct Result: Sendable, Equatable {
        public var added = 0
        public var replaced = 0
        public var skipped = 0
        public var secretsStored = 0
        public var keysMovedToKeychain = 0
        public var knownHostsAdded = 0
        public var proxyPasswordsStored = 0
    }

    public let document: TepfaDocument
    public private(set) var items: [Item]

    public init(document: TepfaDocument, context: ModelContext, knownHosts: [KnownHostEntry]) throws {
        self.document = document
        var items: [Item] = []

        let groups = Dictionary(try context.fetch(FetchDescriptor<HostGroup>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for record in document.groups {
            let current = groups[record.id].map(TepfaDocument.GroupRecord.init)
            items.append(Self.item(kind: .group, id: record.id.uuidString, title: record.name, subtitle: "\(groups[record.id]?.hosts.count ?? 0) hosts", incoming: record, current: current))
        }

        let identities = Dictionary(try context.fetch(FetchDescriptor<Identity>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for record in document.identities {
            let current = identities[record.id].map(TepfaDocument.IdentityRecord.init)
            var subtitle = CredentialKind(rawValue: record.credentialKind)?.displayName ?? record.credentialKind
            if !record.username.isEmpty { subtitle = record.username + " · " + subtitle }
            if document.secrets?.identities[record.id.uuidString] != nil { subtitle += " · includes secret" }
            items.append(Self.item(kind: .identity, id: record.id.uuidString, title: record.name, subtitle: subtitle, incoming: record, current: current))
        }

        let folders = Dictionary(try context.fetch(FetchDescriptor<SnippetFolder>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for record in document.snippetFolders {
            let current = folders[record.id].map(TepfaDocument.SnippetFolderRecord.init)
            items.append(Self.item(kind: .snippetFolder, id: record.id.uuidString, title: record.name, subtitle: "", incoming: record, current: current))
        }

        let snippets = Dictionary(try context.fetch(FetchDescriptor<Snippet>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for record in document.snippets {
            let current = snippets[record.id].map(TepfaDocument.SnippetRecord.init)
            let firstLine = record.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            items.append(Self.item(kind: .snippet, id: record.id.uuidString, title: record.name, subtitle: firstLine, incoming: record, current: current))
        }

        let hosts = Dictionary(try context.fetch(FetchDescriptor<SSHHost>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for var record in document.hosts {
            let current = hosts[record.id].map(TepfaDocument.HostRecord.init)
            // Files written before the agent fields existed keep the current values rather than showing a change.
            if record.agentPermission == nil { record.agentPermission = current?.agentPermission ?? AgentPermissionMode.ask.rawValue }
            if record.agentAllowlist == nil { record.agentAllowlist = current?.agentAllowlist ?? [] }
            if record.inheritsGroupJumpHost == nil { record.inheritsGroupJumpHost = current?.inheritsGroupJumpHost ?? true }
            if record.inheritsGroupProxy == nil { record.inheritsGroupProxy = current?.inheritsGroupProxy ?? true }
            let target = record.port == 22 ? "\(record.username)@\(record.hostname)" : "\(record.username)@\(record.hostname):\(record.port)"
            items.append(Self.item(kind: .host, id: record.id.uuidString, title: record.name, subtitle: target, incoming: record, current: current))
        }

        let rules = Dictionary(try context.fetch(FetchDescriptor<PortForwardRule>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let hostNames = Dictionary(document.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for var record in document.portForwards {
            let current = rules[record.id].flatMap(TepfaDocument.PortForwardRecord.init)
            if record.name == nil { record.name = current?.name ?? "" }
            if record.sortOrder == nil { record.sortOrder = current?.sortOrder ?? 0 }
            let kind = PortForwardKind(rawValue: record.kind) ?? .local
            let summary = PortForwardDescription.describe(kind: kind, bindAddress: record.bindAddress, bindPort: record.bindPort, targetHost: record.targetHost, targetPort: record.targetPort)
            let hostName = hostNames[record.hostID] ?? hosts[record.hostID]?.name ?? "unknown host"
            items.append(Self.item(kind: .portForward, id: record.id.uuidString, title: record.name.flatMap { $0.isEmpty ? nil : $0 } ?? summary, subtitle: "\(hostName) · \(summary)", incoming: record, current: current))
        }

        let themes = Dictionary(try context.fetch(FetchDescriptor<TerminalThemeRecord>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for record in document.themes {
            let current = themes[record.id].flatMap(TepfaDocument.ThemeRecord.init)
            items.append(Self.item(kind: .theme, id: record.id.uuidString, title: record.name, subtitle: record.scheme.isDark ? "Dark" : "Light", incoming: record, current: current))
        }

        let serials = Dictionary(try context.fetch(FetchDescriptor<SerialProfile>()).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for record in document.serialProfiles {
            let current = serials[record.id].map(TepfaDocument.SerialProfileRecord.init)
            items.append(Self.item(kind: .serialProfile, id: record.id.uuidString, title: record.name, subtitle: "\(record.devicePath) · \(record.baudRate)", incoming: record, current: current))
        }

        let known = Dictionary(knownHosts.map { (TepfaDocument.KnownHostRecord($0).id, TepfaDocument.KnownHostRecord($0)) }, uniquingKeysWith: { a, _ in a })
        for record in document.knownHosts {
            items.append(Self.item(kind: .knownHost, id: record.id, title: record.port == 22 ? record.host : "\(record.host):\(record.port)", subtitle: "\(record.keyType) \(record.fingerprintSHA256)", incoming: record, current: known[record.id]))
        }
        self.items = items
    }

    private static func item<R: Codable & Equatable>(kind: Kind, id: String, title: String, subtitle: String, incoming: R, current: R?) -> Item {
        let status: Status
        var changes: [String] = []
        if let current {
            changes = differingFields(incoming, current)
            status = changes.isEmpty ? .identical : .changed
        } else {
            status = .new
        }
        let action: Action = switch status {
        case .new: .add
        case .changed: .replace
        case .identical: .skip
        }
        return Item(id: "\(kind.rawValue):\(id)", kind: kind, recordID: id, title: title, subtitle: subtitle, status: status, action: action, changes: changes)
    }

    /// Top-level JSON field names whose values differ.
    private static func differingFields<R: Codable>(_ a: R, _ b: R) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let da = try? encoder.encode(a), let db = try? encoder.encode(b),
              let oa = try? JSONSerialization.jsonObject(with: da) as? [String: Any],
              let ob = try? JSONSerialization.jsonObject(with: db) as? [String: Any] else { return ["?"] }
        var out: [String] = []
        for key in Set(oa.keys).union(ob.keys).sorted() {
            let va = oa[key].map { ($0 as AnyObject).description } ?? "null"
            let vb = ob[key].map { ($0 as AnyObject).description } ?? "null"
            if va != vb { out.append(key) }
        }
        return out
    }

    // MARK: - Choices

    public func items(of kind: Kind) -> [Item] {
        items.filter { $0.kind == kind }
    }

    public var kinds: [Kind] {
        Kind.allCases.filter { kind in items.contains { $0.kind == kind } }
    }

    public func count(_ status: Status) -> Int {
        items.filter { $0.status == status }.count
    }

    public var importedCount: Int {
        items.filter { $0.isImported }.count
    }

    public mutating func setAction(_ action: Action, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].action = action
    }

    /// Imports (`true`) or skips (`false`) every record with `status`.
    public mutating func setImported(_ imported: Bool, status: Status) {
        for index in items.indices where items[index].status == status {
            items[index].action = imported ? (status == .new ? .add : .replace) : .skip
        }
    }

    // MARK: - Apply

    /// Writes the chosen records. `secretWriter` stores a password, key or
    /// passphrase for an identity (in the Keychain); it is called after the
    /// identity exists.
    public func apply(
        to context: ModelContext,
        knownHosts: KnownHostsStore?,
        secretWriter: ((Identity, TepfaDocument.IdentitySecrets) throws -> Void)? = nil,
        proxyPasswordWriter: ((UUID, String) throws -> Void)? = nil
    ) async throws -> Result {
        var result = Result()
        let chosen = Dictionary(items.map { ($0.id, $0.action) }, uniquingKeysWith: { a, _ in a })
        func action(_ kind: Kind, _ id: String) -> Action { chosen["\(kind.rawValue):\(id)"] ?? .skip }
        func count(_ action: Action) {
            switch action {
            case .add: result.added += 1
            case .replace: result.replaced += 1
            case .skip: result.skipped += 1
            }
        }

        for record in document.groups {
            let action = action(.group, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            let group = try Self.group(record.id, in: context) ?? {
                let created = HostGroup(uuid: record.id, name: record.name)
                context.insert(created)
                return created
            }()
            group.name = record.name
            group.sortOrder = record.sortOrder
            group.colorLabel = record.colorLabel
            group.themeID = record.themeID
            group.fontName = record.fontName
            group.fontSize = record.fontSize
            Self.apply(proxy: record.proxy, kind: &group.proxyKindRaw, host: &group.proxyHost, port: &group.proxyPort, username: &group.proxyUsername)
            if let password = document.secrets?.proxyPasswords[record.id.uuidString], let proxyPasswordWriter {
                try proxyPasswordWriter(record.id, password)
                result.proxyPasswordsStored += 1
            }
        }

        for record in document.identities {
            let action = action(.identity, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            let identity = try Self.identity(record.id, in: context) ?? {
                let created = Identity(uuid: record.id, name: record.name)
                context.insert(created)
                return created
            }()
            identity.name = record.name
            identity.username = record.username
            identity.credentialKindRaw = record.credentialKind
            identity.privateKeyPath = record.privateKeyPath
            identity.publicKey = record.publicKey
            identity.keyType = record.keyType
            identity.fingerprint = record.fingerprint
            if var secrets = document.secrets?.identities[record.id.uuidString], let secretWriter {
                if identity.credentialKind == .keyFile, secrets.privateKey != nil {
                    let expanded = (identity.privateKeyPath as NSString).expandingTildeInPath
                    if identity.privateKeyPath.isEmpty || !FileManager.default.fileExists(atPath: expanded) {
                        // The file is not on this Mac: keep the key in the Keychain instead.
                        identity.credentialKind = .keychainKey
                        identity.privateKeyPath = ""
                        secrets.passphrase = nil
                        result.keysMovedToKeychain += 1
                    } else {
                        // The file exists here; only its passphrase is worth storing.
                        secrets.privateKey = nil
                    }
                }
                if !secrets.isEmpty {
                    try secretWriter(identity, secrets)
                    result.secretsStored += 1
                }
            }
        }

        for record in document.snippetFolders {
            let action = action(.snippetFolder, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            let folder = try Self.folder(record.id, in: context) ?? {
                let created = SnippetFolder(uuid: record.id, name: record.name)
                context.insert(created)
                return created
            }()
            folder.name = record.name
            folder.sortOrder = record.sortOrder
        }

        for record in document.snippets {
            let action = action(.snippet, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            let snippet = try Self.snippet(record.id, in: context) ?? {
                let created = Snippet(uuid: record.id, name: record.name, command: record.command)
                context.insert(created)
                return created
            }()
            snippet.name = record.name
            snippet.command = record.command
            snippet.tags = record.tags
            snippet.notes = record.notes
            snippet.sortOrder = record.sortOrder
            snippet.folder = try record.folderID.flatMap { try Self.folder($0, in: context) }
        }

        for record in document.hosts {
            let action = action(.host, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            let host = try Self.host(record.id, in: context) ?? {
                let created = SSHHost(uuid: record.id, name: record.name, hostname: record.hostname, username: record.username)
                context.insert(created)
                return created
            }()
            host.name = record.name
            host.hostname = record.hostname
            host.port = record.port
            host.username = record.username
            host.authMethodRaw = record.authMethod
            host.tags = record.tags
            host.notes = record.notes
            host.sortOrder = record.sortOrder
            host.colorLabel = record.colorLabel
            host.autoReconnect = record.autoReconnect
            host.shellIntegrationRaw = record.shellIntegration
            if let permission = record.agentPermission { host.agentPermissionRaw = permission }
            if let allowlist = record.agentAllowlist { host.agentAllowlist = allowlist }
            host.group = try record.groupID.flatMap { try Self.group($0, in: context) }
            host.identity = try record.identityID.flatMap { try Self.identity($0, in: context) }
            host.defaultSnippet = try record.defaultSnippetID.flatMap { try Self.snippet($0, in: context) }
            if let inherits = record.inheritsGroupJumpHost { host.inheritsGroupJumpHost = inherits }
            if let inherits = record.inheritsGroupProxy { host.inheritsGroupProxy = inherits }
            host.themeID = record.themeID
            host.fontName = record.fontName
            host.fontSize = record.fontSize
            host.backgroundTint = record.backgroundTint
            host.watermark = record.watermark
            Self.apply(proxy: record.proxy, kind: &host.proxyKindRaw, host: &host.proxyHost, port: &host.proxyPort, username: &host.proxyUsername)
            if let password = document.secrets?.proxyPasswords[record.id.uuidString], let proxyPasswordWriter {
                try proxyPasswordWriter(record.id, password)
                result.proxyPasswordsStored += 1
            }
        }

        // Jump hosts and group defaults refer to hosts, so they are linked once every host exists.
        for record in document.hosts where action(.host, record.id.uuidString) != .skip {
            guard let host = try Self.host(record.id, in: context) else { continue }
            host.jumpHost = try record.jumpHostID.flatMap { id in id == record.id ? nil : try Self.host(id, in: context) }
        }
        for record in document.groups where action(.group, record.id.uuidString) != .skip {
            guard let group = try Self.group(record.id, in: context) else { continue }
            group.defaultIdentity = try record.defaultIdentityID.flatMap { try Self.identity($0, in: context) }
            group.defaultJumpHost = try record.defaultJumpHostID.flatMap { try Self.host($0, in: context) }
        }
        for record in document.hosts where action(.host, record.id.uuidString) != .skip {
            guard let host = try Self.host(record.id, in: context) else { continue }
            if host.identity == nil, host.authMethod == .privateKey, host.group?.defaultIdentity == nil {
                // Neither the host's identity nor a group default was imported; ask for a password instead.
                host.authMethod = .password
            }
        }

        for record in document.portForwards {
            let action = action(.portForward, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            guard let host = try Self.host(record.hostID, in: context) else {
                result.skipped += 1
                continue
            }
            let rule = try Self.rule(record.id, in: context) ?? {
                let created = PortForwardRule(uuid: record.id, bindPort: record.bindPort)
                context.insert(created)
                return created
            }()
            rule.name = record.name ?? ""
            rule.kindRaw = record.kind
            rule.bindAddress = record.bindAddress
            rule.bindPort = record.bindPort
            rule.targetHost = record.targetHost
            rule.targetPort = record.targetPort
            rule.autoStart = record.autoStart
            rule.sortOrder = record.sortOrder ?? 0
            rule.host = host
        }

        for record in document.themes {
            let action = action(.theme, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            var scheme = record.scheme
            scheme.id = record.id.uuidString
            scheme.name = record.name
            let json = try scheme.encodedJSON()
            let theme = try Self.theme(record.id, in: context) ?? {
                let created = TerminalThemeRecord(uuid: record.id, name: record.name, schemeJSON: json, source: record.source ?? "import")
                context.insert(created)
                return created
            }()
            theme.name = record.name
            theme.schemeJSON = json
            theme.updatedAt = .now
            if let source = record.source { theme.source = source }
        }

        for record in document.serialProfiles {
            let action = action(.serialProfile, record.id.uuidString)
            count(action)
            guard action != .skip else { continue }
            let profile = try Self.serialProfile(record.id, in: context) ?? {
                let created = SerialProfile(uuid: record.id, name: record.name, devicePath: record.devicePath)
                context.insert(created)
                return created
            }()
            profile.name = record.name
            profile.devicePath = record.devicePath
            profile.baudRate = record.baudRate
            profile.dataBits = record.dataBits
            profile.parityRaw = record.parity
            profile.stopBits = record.stopBits
            profile.flowControlRaw = record.flowControl
            profile.sendLineEndingRaw = record.sendLineEnding
            profile.convertIncomingLF = record.convertIncomingLF
            profile.localEcho = record.localEcho
            profile.hexView = record.hexView
            profile.colorLabel = record.colorLabel
            profile.sortOrder = record.sortOrder
        }

        if let knownHosts {
            for record in document.knownHosts {
                let action = action(.knownHost, record.id)
                count(action)
                guard action != .skip else { continue }
                _ = try await knownHosts.remember(host: record.host, port: record.port, keyType: record.keyType, publicKey: record.publicKey, fingerprintSHA256: record.fingerprintSHA256)
                result.knownHostsAdded += 1
            }
        }

        try context.save()
        return result
    }

    // MARK: - Lookups

    static func group(_ id: UUID, in context: ModelContext) throws -> HostGroup? {
        try context.fetch(FetchDescriptor<HostGroup>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func identity(_ id: UUID, in context: ModelContext) throws -> Identity? {
        try context.fetch(FetchDescriptor<Identity>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func folder(_ id: UUID, in context: ModelContext) throws -> SnippetFolder? {
        try context.fetch(FetchDescriptor<SnippetFolder>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func snippet(_ id: UUID, in context: ModelContext) throws -> Snippet? {
        try context.fetch(FetchDescriptor<Snippet>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func host(_ id: UUID, in context: ModelContext) throws -> SSHHost? {
        try context.fetch(FetchDescriptor<SSHHost>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func rule(_ id: UUID, in context: ModelContext) throws -> PortForwardRule? {
        try context.fetch(FetchDescriptor<PortForwardRule>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func theme(_ id: UUID, in context: ModelContext) throws -> TerminalThemeRecord? {
        try context.fetch(FetchDescriptor<TerminalThemeRecord>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func serialProfile(_ id: UUID, in context: ModelContext) throws -> SerialProfile? {
        try context.fetch(FetchDescriptor<SerialProfile>(predicate: #Predicate { $0.uuid == id })).first
    }

    static func apply(proxy: TepfaDocument.ProxyRecord?, kind: inout String?, host: inout String, port: inout Int, username: inout String) {
        if let proxy {
            kind = proxy.kind
            host = proxy.host
            port = proxy.port
            username = proxy.username ?? ""
        } else {
            kind = nil
            host = ""
            port = 0
            username = ""
        }
    }
}
