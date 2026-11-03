import Foundation

/// The versioned JSON payload of a `.tepfa` file. Records carry the stable
/// UUIDs of the SwiftData models so repeated imports never create copies.
/// Timestamps that change on their own (last connection, creation) are left
/// out so "changed" means the user changed something.
public struct TepfaDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var format: String = "tepfa"
    public var schemaVersion: Int = currentSchemaVersion
    public var exportedAt: Date
    public var appVersion: String?
    public var groups: [GroupRecord] = []
    public var hosts: [HostRecord] = []
    public var identities: [IdentityRecord] = []
    public var snippetFolders: [SnippetFolderRecord] = []
    public var snippets: [SnippetRecord] = []
    public var knownHosts: [KnownHostRecord] = []
    public var portForwards: [PortForwardRecord] = []
    public var themes: [ThemeRecord] = []
    public var serialProfiles: [SerialProfileRecord] = []
    /// Passwords, keys and passphrases. Only ever present in encrypted files.
    public var secrets: SecretsRecord?

    public init(exportedAt: Date = .now, appVersion: String? = nil) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, exportedAt, appVersion, groups, hosts, identities, snippetFolders, snippets, knownHosts, portForwards, themes, serialProfiles, secrets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "tepfa"
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? .distantPast
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        groups = try container.decodeIfPresent([GroupRecord].self, forKey: .groups) ?? []
        hosts = try container.decodeIfPresent([HostRecord].self, forKey: .hosts) ?? []
        identities = try container.decodeIfPresent([IdentityRecord].self, forKey: .identities) ?? []
        snippetFolders = try container.decodeIfPresent([SnippetFolderRecord].self, forKey: .snippetFolders) ?? []
        snippets = try container.decodeIfPresent([SnippetRecord].self, forKey: .snippets) ?? []
        knownHosts = try container.decodeIfPresent([KnownHostRecord].self, forKey: .knownHosts) ?? []
        portForwards = try container.decodeIfPresent([PortForwardRecord].self, forKey: .portForwards) ?? []
        themes = try container.decodeIfPresent([ThemeRecord].self, forKey: .themes) ?? []
        serialProfiles = try container.decodeIfPresent([SerialProfileRecord].self, forKey: .serialProfiles) ?? []
        secrets = try container.decodeIfPresent(SecretsRecord.self, forKey: .secrets)
    }

    public var isEmpty: Bool {
        groups.isEmpty && hosts.isEmpty && identities.isEmpty && snippetFolders.isEmpty && snippets.isEmpty && knownHosts.isEmpty && portForwards.isEmpty && themes.isEmpty && serialProfiles.isEmpty
    }

    public struct GroupRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var sortOrder: Int
        public var colorLabel: String?
        /// Group defaults (section 6 and theming). Optional so older files decode.
        public var defaultIdentityID: UUID?
        public var defaultJumpHostID: UUID?
        public var proxy: ProxyRecord?
        public var themeID: String?
        public var fontName: String?
        public var fontSize: Double?

        public init(id: UUID, name: String, sortOrder: Int = 0, colorLabel: String? = nil, defaultIdentityID: UUID? = nil, defaultJumpHostID: UUID? = nil, proxy: ProxyRecord? = nil, themeID: String? = nil, fontName: String? = nil, fontSize: Double? = nil) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
            self.colorLabel = colorLabel
            self.defaultIdentityID = defaultIdentityID
            self.defaultJumpHostID = defaultJumpHostID
            self.proxy = proxy
            self.themeID = themeID
            self.fontName = fontName
            self.fontSize = fontSize
        }
    }

    /// A proxy on a host or group. The password, when exported, travels in `secrets`.
    public struct ProxyRecord: Codable, Sendable, Equatable {
        public var kind: String
        public var host: String
        public var port: Int
        public var username: String?

        public init(kind: String, host: String, port: Int, username: String? = nil) {
            self.kind = kind
            self.host = host
            self.port = port
            self.username = username
        }
    }

    public struct HostRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var hostname: String
        public var port: Int
        public var username: String
        public var authMethod: String
        public var tags: [String]
        public var notes: String
        public var sortOrder: Int
        public var colorLabel: String?
        public var autoReconnect: Bool
        public var groupID: UUID?
        public var identityID: UUID?
        public var defaultSnippetID: UUID?
        public var shellIntegration: String
        /// Agent guardrails (build step 7). Optional so files written before they existed still decode.
        public var agentPermission: String?
        public var agentAllowlist: [String]?
        /// Jump host, proxy and theming (later steps). Optional for the same reason.
        public var jumpHostID: UUID?
        public var inheritsGroupJumpHost: Bool?
        public var proxy: ProxyRecord?
        public var inheritsGroupProxy: Bool?
        public var themeID: String?
        public var fontName: String?
        public var fontSize: Double?
        public var backgroundTint: String?
        public var watermark: String?

        public init(
            id: UUID, name: String, hostname: String, port: Int = 22, username: String, authMethod: String = AuthMethod.password.rawValue,
            tags: [String] = [], notes: String = "", sortOrder: Int = 0, colorLabel: String? = nil, autoReconnect: Bool = true,
            groupID: UUID? = nil, identityID: UUID? = nil, defaultSnippetID: UUID? = nil, shellIntegration: String = ShellIntegrationMode.automatic.rawValue,
            agentPermission: String? = nil, agentAllowlist: [String]? = nil,
            jumpHostID: UUID? = nil, inheritsGroupJumpHost: Bool? = nil, proxy: ProxyRecord? = nil, inheritsGroupProxy: Bool? = nil,
            themeID: String? = nil, fontName: String? = nil, fontSize: Double? = nil, backgroundTint: String? = nil, watermark: String? = nil
        ) {
            self.id = id
            self.name = name
            self.hostname = hostname
            self.port = port
            self.username = username
            self.authMethod = authMethod
            self.tags = tags
            self.notes = notes
            self.sortOrder = sortOrder
            self.colorLabel = colorLabel
            self.autoReconnect = autoReconnect
            self.groupID = groupID
            self.identityID = identityID
            self.defaultSnippetID = defaultSnippetID
            self.shellIntegration = shellIntegration
            self.agentPermission = agentPermission
            self.agentAllowlist = agentAllowlist
            self.jumpHostID = jumpHostID
            self.inheritsGroupJumpHost = inheritsGroupJumpHost
            self.proxy = proxy
            self.inheritsGroupProxy = inheritsGroupProxy
            self.themeID = themeID
            self.fontName = fontName
            self.fontSize = fontSize
            self.backgroundTint = backgroundTint
            self.watermark = watermark
        }
    }

    public struct IdentityRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var username: String
        public var credentialKind: String
        public var privateKeyPath: String
        public var publicKey: String?
        public var keyType: String?
        public var fingerprint: String?

        public init(id: UUID, name: String, username: String = "", credentialKind: String = CredentialKind.keyFile.rawValue, privateKeyPath: String = "", publicKey: String? = nil, keyType: String? = nil, fingerprint: String? = nil) {
            self.id = id
            self.name = name
            self.username = username
            self.credentialKind = credentialKind
            self.privateKeyPath = privateKeyPath
            self.publicKey = publicKey
            self.keyType = keyType
            self.fingerprint = fingerprint
        }
    }

    public struct SnippetFolderRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var sortOrder: Int

        public init(id: UUID, name: String, sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
        }
    }

    public struct SnippetRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var command: String
        public var tags: [String]
        public var notes: String
        public var sortOrder: Int
        public var folderID: UUID?

        public init(id: UUID, name: String, command: String, tags: [String] = [], notes: String = "", sortOrder: Int = 0, folderID: UUID? = nil) {
            self.id = id
            self.name = name
            self.command = command
            self.tags = tags
            self.notes = notes
            self.sortOrder = sortOrder
            self.folderID = folderID
        }
    }

    public struct KnownHostRecord: Codable, Sendable, Equatable, Identifiable {
        public var host: String
        public var port: Int
        public var keyType: String
        public var publicKey: String
        public var fingerprintSHA256: String

        public var id: String { "\(host):\(port) \(keyType)" }

        public init(host: String, port: Int, keyType: String, publicKey: String, fingerprintSHA256: String) {
            self.host = host
            self.port = port
            self.keyType = keyType
            self.publicKey = publicKey
            self.fingerprintSHA256 = fingerprintSHA256
        }

        public init(_ entry: KnownHostEntry) {
            self.init(host: entry.host, port: entry.port, keyType: entry.keyType, publicKey: entry.publicKey, fingerprintSHA256: entry.fingerprintSHA256)
        }
    }

    public struct PortForwardRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var hostID: UUID
        public var kind: String
        public var bindAddress: String
        public var bindPort: Int
        public var targetHost: String
        public var targetPort: Int
        public var autoStart: Bool
        public var name: String?
        public var sortOrder: Int?

        public init(id: UUID, hostID: UUID, kind: String, bindAddress: String = "127.0.0.1", bindPort: Int, targetHost: String = "", targetPort: Int = 0, autoStart: Bool = false, name: String? = nil, sortOrder: Int? = nil) {
            self.id = id
            self.hostID = hostID
            self.kind = kind
            self.bindAddress = bindAddress
            self.bindPort = bindPort
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.autoStart = autoStart
            self.name = name
            self.sortOrder = sortOrder
        }
    }

    public struct ThemeRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var source: String?
        public var scheme: TerminalTheme

        public init(id: UUID, name: String, source: String? = nil, scheme: TerminalTheme) {
            self.id = id
            self.name = name
            self.source = source
            self.scheme = scheme
        }
    }

    public struct SerialProfileRecord: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var devicePath: String
        public var baudRate: Int
        public var dataBits: Int
        public var parity: String
        public var stopBits: Int
        public var flowControl: String
        public var sendLineEnding: String
        public var convertIncomingLF: Bool
        public var localEcho: Bool
        public var hexView: Bool
        public var colorLabel: String?
        public var sortOrder: Int

        public init(id: UUID, name: String, devicePath: String, baudRate: Int = 115_200, dataBits: Int = 8, parity: String = "none", stopBits: Int = 1, flowControl: String = "none", sendLineEnding: String = "cr", convertIncomingLF: Bool = true, localEcho: Bool = false, hexView: Bool = false, colorLabel: String? = nil, sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.devicePath = devicePath
            self.baudRate = baudRate
            self.dataBits = dataBits
            self.parity = parity
            self.stopBits = stopBits
            self.flowControl = flowControl
            self.sendLineEnding = sendLineEnding
            self.convertIncomingLF = convertIncomingLF
            self.localEcho = localEcho
            self.hexView = hexView
            self.colorLabel = colorLabel
            self.sortOrder = sortOrder
        }
    }

    public struct IdentitySecrets: Codable, Sendable, Equatable {
        public var password: String?
        /// OpenSSH-format private key text (unencrypted inside the encrypted file).
        public var privateKey: String?
        public var passphrase: String?

        public init(password: String? = nil, privateKey: String? = nil, passphrase: String? = nil) {
            self.password = password
            self.privateKey = privateKey
            self.passphrase = passphrase
        }

        public var isEmpty: Bool { password == nil && privateKey == nil && passphrase == nil }
    }

    public struct SecretsRecord: Codable, Sendable, Equatable {
        /// Keyed by identity UUID string.
        public var identities: [String: IdentitySecrets]
        /// Proxy passwords keyed by the owning host's or group's UUID string.
        public var proxyPasswords: [String: String]

        public init(identities: [String: IdentitySecrets] = [:], proxyPasswords: [String: String] = [:]) {
            self.identities = identities
            self.proxyPasswords = proxyPasswords
        }

        private enum CodingKeys: String, CodingKey { case identities, proxyPasswords }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identities = try container.decodeIfPresent([String: IdentitySecrets].self, forKey: .identities) ?? [:]
            proxyPasswords = try container.decodeIfPresent([String: String].self, forKey: .proxyPasswords) ?? [:]
        }

        public var isEmpty: Bool { identities.isEmpty && proxyPasswords.isEmpty }
    }
}
