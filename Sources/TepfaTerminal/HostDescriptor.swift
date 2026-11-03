import Foundation
import TepfaCore

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

/// An immutable, Sendable snapshot of the fields a session needs from an `SSHHost`.
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
        agentAllowlist: [String] = []
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, authMethod, identity, colorLabel, autoReconnect, isTransient, startupCommand, shellIntegration, agentPermission, agentAllowlist
    }

    /// Tolerates snapshots written before `startupCommand` and `shellIntegration` existed.
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
            agentAllowlist: try container.decodeIfPresent([String].self, forKey: .agentAllowlist) ?? [])
    }

    @MainActor
    public init(_ host: SSHHost) {
        self.init(
            id: host.uuid,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: host.authMethod,
            identity: host.identity.map(IdentityDescriptor.init),
            colorLabel: host.colorLabel ?? host.group?.colorLabel,
            autoReconnect: host.autoReconnect,
            isTransient: false,
            startupCommand: host.defaultSnippet.map { snippet in
                SnippetVariables.substitute(snippet.command, values: [:])
            },
            shellIntegration: host.shellIntegration,
            agentPermission: host.agentPermission,
            agentAllowlist: host.agentAllowlist)
    }

    /// The login name actually sent: the identity's when it has one, else the host's.
    public var loginUsername: String {
        if let identity, !identity.username.isEmpty { return identity.username }
        return username
    }

    /// True when connecting will not need to ask the user anything (keys, or a
    /// password the store may hold). Used to decide which tabs auto-reconnect at launch.
    public var usesIdentity: Bool { identity != nil }

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

    /// `user@host[:port]`
    public var target: String {
        port == 22 ? "\(loginUsername)@\(hostname)" : "\(loginUsername)@\(hostname):\(port)"
    }
}
