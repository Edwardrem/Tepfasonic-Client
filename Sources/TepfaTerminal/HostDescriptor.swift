import Foundation
import TepfaCore
import TepfaSSH

/// Sendable snapshot of an `Identity`: what the credential store needs to find
/// the secret, never the secret itself.
public struct IdentityDescriptor: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    /// Empty means "use the host's username".
    public let username: String
    public let kind: CredentialKind
    public let privateKeyPath: String
    public let keyType: String?
    public let fingerprint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        username: String = "",
        kind: CredentialKind,
        privateKeyPath: String = "",
        keyType: String? = nil,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.kind = kind
        self.privateKeyPath = privateKeyPath
        self.keyType = keyType
        self.fingerprint = fingerprint
    }

    @MainActor
    public init(_ identity: Identity) {
        self.init(
            id: identity.uuid,
            name: identity.name,
            username: identity.username,
            kind: identity.credentialKind,
            privateKeyPath: identity.privateKeyPath,
            keyType: identity.keyType,
            fingerprint: identity.fingerprint)
    }
}

/// Terminal look settings resolved for one host (host, then group, then global).
public struct HostAppearance: Sendable, Hashable, Codable {
    /// `builtin:<slug>`, a saved theme UUID, or nil for the global scheme.
    public var themeID: String?
    public var fontName: String?
    public var fontSize: Double?
    public var backgroundTint: String?
    public var watermark: String?

    public init(themeID: String? = nil, fontName: String? = nil, fontSize: Double? = nil, backgroundTint: String? = nil, watermark: String? = nil) {
        self.themeID = themeID
        self.fontName = fontName
        self.fontSize = fontSize
        self.backgroundTint = backgroundTint
        self.watermark = watermark
    }

    public var isEmpty: Bool { themeID == nil && fontName == nil && fontSize == nil && backgroundTint == nil && watermark == nil }
}

/// An immutable, Sendable snapshot of the fields a session needs from an `SSHHost`.
///
/// A descriptor can also describe a serial console (`serial` set): the
/// session then opens the device instead of an SSH connection, and the
/// hostname carries the device path.
public struct HostDescriptor: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authMethod: AuthMethod
    public let identity: IdentityDescriptor?
    public let colorLabel: String?
    public let autoReconnect: Bool
    /// True for quick-connect targets that are not saved hosts.
    public let isTransient: Bool
    /// Sent to the shell once it is ready, after connecting (the host's default snippet).
    public let startupCommand: String?
    public let shellIntegration: ShellIntegrationMode
    /// What the Claude agent may run here without asking.
    public let agentPermission: AgentPermissionMode
    public let agentAllowlist: [String]
    /// Bastions to go through, outermost first: the first hop is reached directly
    /// (or through `proxy`), each later hop through the one before it, and the
    /// host itself through the last.
    public let jumpChain: [HostDescriptor]
    /// Proxy for the first TCP connection of the chain.
    public let proxy: HostProxyConfiguration?
    public let appearance: HostAppearance
    /// Set for serial consoles.
    public let serial: SerialSettings?

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        identity: IdentityDescriptor? = nil,
        colorLabel: String? = nil,
        autoReconnect: Bool = true,
        isTransient: Bool = false,
        startupCommand: String? = nil,
        shellIntegration: ShellIntegrationMode = .automatic,
        agentPermission: AgentPermissionMode = .ask,
        agentAllowlist: [String] = [],
        jumpChain: [HostDescriptor] = [],
        proxy: HostProxyConfiguration? = nil,
        appearance: HostAppearance = HostAppearance(),
        serial: SerialSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.identity = identity
        self.colorLabel = colorLabel
        self.autoReconnect = autoReconnect
        self.isTransient = isTransient
        self.startupCommand = startupCommand
        self.shellIntegration = shellIntegration
        self.agentPermission = agentPermission
        self.agentAllowlist = agentAllowlist
        self.jumpChain = jumpChain
        self.proxy = proxy
        self.appearance = appearance
        self.serial = serial
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, authMethod, identity, colorLabel, autoReconnect, isTransient, startupCommand, shellIntegration, agentPermission, agentAllowlist, jumpChain, proxy, appearance, serial
    }

    /// Tolerates snapshots written before the later fields existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            hostname: try container.decode(String.self, forKey: .hostname),
            port: try container.decode(Int.self, forKey: .port),
            username: try container.decode(String.self, forKey: .username),
            authMethod: try container.decode(AuthMethod.self, forKey: .authMethod),
            identity: try container.decodeIfPresent(IdentityDescriptor.self, forKey: .identity),
            colorLabel: try container.decodeIfPresent(String.self, forKey: .colorLabel),
            autoReconnect: try container.decode(Bool.self, forKey: .autoReconnect),
            isTransient: try container.decode(Bool.self, forKey: .isTransient),
            startupCommand: try container.decodeIfPresent(String.self, forKey: .startupCommand),
            shellIntegration: try container.decodeIfPresent(ShellIntegrationMode.self, forKey: .shellIntegration) ?? .automatic,
            agentPermission: try container.decodeIfPresent(AgentPermissionMode.self, forKey: .agentPermission) ?? .ask,
            agentAllowlist: try container.decodeIfPresent([String].self, forKey: .agentAllowlist) ?? [],
            jumpChain: try container.decodeIfPresent([HostDescriptor].self, forKey: .jumpChain) ?? [],
            proxy: try container.decodeIfPresent(HostProxyConfiguration.self, forKey: .proxy),
            appearance: try container.decodeIfPresent(HostAppearance.self, forKey: .appearance) ?? HostAppearance(),
            serial: try container.decodeIfPresent(SerialSettings.self, forKey: .serial))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(identity, forKey: .identity)
        try container.encodeIfPresent(colorLabel, forKey: .colorLabel)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encode(isTransient, forKey: .isTransient)
        try container.encodeIfPresent(startupCommand, forKey: .startupCommand)
        try container.encode(shellIntegration, forKey: .shellIntegration)
        try container.encode(agentPermission, forKey: .agentPermission)
        try container.encode(agentAllowlist, forKey: .agentAllowlist)
        if !jumpChain.isEmpty { try container.encode(jumpChain, forKey: .jumpChain) }
        try container.encodeIfPresent(proxy, forKey: .proxy)
        if !appearance.isEmpty { try container.encode(appearance, forKey: .appearance) }
        try container.encodeIfPresent(serial, forKey: .serial)
    }

    /// The most hops a chain may have; deeper chains are cut (and a cycle is broken) here.
    public static let maximumJumpDepth = 8

    @MainActor
    public init(_ host: SSHHost) {
        self.init(host, visited: [host.uuid])
    }

    /// Builds the descriptor and its jump chain. `visited` breaks cycles.
    @MainActor
    private init(_ host: SSHHost, visited: Set<UUID>) {
        var chain: [HostDescriptor] = []
        if let jump = host.effectiveJumpHost, !visited.contains(jump.uuid), visited.count < Self.maximumJumpDepth {
            let bastion = HostDescriptor(jump, visited: visited.union([jump.uuid]))
            chain = bastion.jumpChain + [bastion.withoutJumpChain()]
        }
        let identity = host.effectiveIdentity
        let group = host.group
        self.init(
            id: host.uuid,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: identity != nil ? .privateKey : host.authMethod,
            identity: identity.map(IdentityDescriptor.init),
            colorLabel: host.colorLabel ?? group?.colorLabel,
            autoReconnect: host.autoReconnect,
            isTransient: false,
            startupCommand: host.defaultSnippet.map { snippet in
                SnippetVariables.substitute(snippet.command, values: [:])
            },
            shellIntegration: host.shellIntegration,
            agentPermission: host.agentPermission,
            agentAllowlist: host.agentAllowlist,
            jumpChain: chain,
            proxy: host.effectiveProxy,
            appearance: HostAppearance(
                themeID: host.themeID ?? group?.themeID,
                fontName: host.fontName ?? group?.fontName,
                fontSize: host.fontSize ?? group?.fontSize,
                backgroundTint: host.backgroundTint,
                watermark: host.watermark))
    }

    /// A serial console as a descriptor; `hostname` is the device path.
    @MainActor
    public init(_ profile: SerialProfile) {
        self.init(
            id: profile.uuid,
            name: profile.name,
            hostname: profile.devicePath,
            port: 0,
            username: "",
            authMethod: .password,
            colorLabel: profile.colorLabel,
            autoReconnect: true,
            shellIntegration: .disabled,
            agentPermission: .readOnly,
            serial: SerialSettings(profile))
    }

    /// The same host without its chain (a hop inside another chain).
    func withoutJumpChain() -> HostDescriptor {
        HostDescriptor(
            id: id, name: name, hostname: hostname, port: port, username: username, authMethod: authMethod, identity: identity,
            colorLabel: colorLabel, autoReconnect: autoReconnect, isTransient: isTransient, startupCommand: nil,
            shellIntegration: shellIntegration, agentPermission: agentPermission, agentAllowlist: agentAllowlist,
            jumpChain: [], proxy: proxy, appearance: appearance, serial: nil)
    }

    public var isSerial: Bool { serial != nil }

    /// The login name actually sent: the identity's when it has one, else the host's.
    public var loginUsername: String {
        if let identity, !identity.username.isEmpty { return identity.username }
        return username
    }

    /// True when connecting will not need to ask the user anything (keys, or a
    /// password the store may hold). Used to decide which tabs auto-reconnect at launch.
    public var usesIdentity: Bool { identity != nil || isSerial }

    /// Parses `user@host:port`, `user@host`, `host:port` or `host` into an unsaved descriptor.
    public static func quickConnect(_ input: String, defaultUsername: String = NSUserName()) -> HostDescriptor? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ssh://") { text.removeFirst("ssh://".count) }
        if text.hasPrefix("ssh ") { text.removeFirst("ssh ".count) }
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        var username = defaultUsername
        if let at = text.lastIndex(of: "@") {
            username = String(text[..<at])
            text = String(text[text.index(after: at)...])
        }
        var port = 22
        if let colon = text.lastIndex(of: ":"), !text.hasPrefix("[") {
            guard let parsed = Int(text[text.index(after: colon)...]), (1...65535).contains(parsed) else { return nil }
            port = parsed
            text = String(text[..<colon])
        }
        guard !text.isEmpty, !username.isEmpty else { return nil }
        return HostDescriptor(
            name: port == 22 ? text : "\(text):\(port)",
            hostname: text,
            port: port,
            username: username,
            authMethod: .password,
            isTransient: true)
    }

    /// `user@host[:port]`, or the device and line settings for a serial console.
    public var target: String {
        if let serial { return "\(hostname) · \(serial.lineSummary)" }
        return port == 22 ? "\(loginUsername)@\(hostname)" : "\(loginUsername)@\(hostname):\(port)"
    }

    /// `via bastion1, bastion2` for the status bar; empty without a chain.
    public var routeDescription: String {
        var parts: [String] = []
        if let proxy { parts.append("proxy \(proxy.displayTarget)") }
        if !jumpChain.isEmpty { parts.append("via " + jumpChain.map(\.name).joined(separator: " → ")) }
        return parts.joined(separator: ", ")
    }
}
