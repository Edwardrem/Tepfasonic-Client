import Foundation
import SwiftData

/// A saved SSH host. Named `SSHHost` rather than `Host` because Foundation
/// already exports a `Host` class on macOS.
///
/// `uuid` is the stable identity used by `.tepfa` export/import so repeated
/// imports never create duplicates.
@Model
public final class SSHHost {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    /// Raw `AuthMethod` value. Use `authMethod` instead.
    public var authMethodRaw: String
    public var tags: [String]
    public var notes: String
    public var sortOrder: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?
    /// Hex colour (`#RRGGBB`) shown on the tab, sidebar row and terminal stripe.
    public var colorLabel: String?
    /// Reconnect automatically after a dropped connection or sleep.
    public var autoReconnect: Bool = true
    public var group: HostGroup?
    public var identity: Identity?
    /// Runs once the shell is ready, after connecting.
    public var defaultSnippet: Snippet?
    /// Raw `ShellIntegrationMode`. Use `shellIntegration`.
    public var shellIntegrationRaw: String = ShellIntegrationMode.automatic.rawValue
    /// Raw `AgentPermissionMode`. Use `agentPermission`.
    public var agentPermissionRaw: String = AgentPermissionMode.ask.rawValue
    /// Command patterns that run without asking in `.allowlist` mode (`*` wildcards, or `/regex/`).
    public var agentAllowlist: [String] = []
    /// The bastion this host is reached through. Chains as deep as the jump host's own jump host.
    public var jumpHost: SSHHost?
    /// Hosts whose `jumpHost` is this one.
    @Relationship(deleteRule: .nullify, inverse: \SSHHost.jumpHost)
    public var hostsJumpingThrough: [SSHHost] = []
    /// Groups that use this host as their default jump host.
    @Relationship(deleteRule: .nullify, inverse: \HostGroup.defaultJumpHost)
    public var groupsJumpingThrough: [HostGroup] = []
    /// When true and `jumpHost` is nil, the group's default jump host applies.
    public var inheritsGroupJumpHost: Bool = true
    /// Raw `ProxySettings.Kind` (`http` or `socks5`); nil means no proxy of its own.
    public var proxyKindRaw: String?
    public var proxyHost: String = ""
    public var proxyPort: Int = 0
    public var proxyUsername: String = ""
    /// When true and no proxy is set here, the group's proxy applies.
    public var inheritsGroupProxy: Bool = true
    /// Terminal colour scheme id (`builtin:dracula` or a theme record UUID). Nil inherits the group, then the global setting.
    public var themeID: String?
    public var fontName: String?
    public var fontSize: Double?
    /// Hex colour tinted over the terminal background as a stronger warning (e.g. production).
    public var backgroundTint: String?
    /// Large faint text drawn over the terminal, such as `PROD`.
    public var watermark: String?
    /// Saved forwarding rules for this host.
    @Relationship(deleteRule: .cascade, inverse: \PortForwardRule.host)
    public var portForwards: [PortForwardRule] = []

    public init(
        uuid: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        tags: [String] = [],
        notes: String = "",
        sortOrder: Int = 0,
        colorLabel: String? = nil,
        autoReconnect: Bool = true,
        group: HostGroup? = nil,
        identity: Identity? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.tags = tags
        self.notes = notes
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.lastConnectedAt = nil
        self.colorLabel = colorLabel
        self.autoReconnect = autoReconnect
        self.group = group
        self.identity = identity
    }

    public var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    public var shellIntegration: ShellIntegrationMode {
        get { ShellIntegrationMode(rawValue: shellIntegrationRaw) ?? .automatic }
        set { shellIntegrationRaw = newValue.rawValue }
    }

    public var agentPermission: AgentPermissionMode {
        get { AgentPermissionMode(rawValue: agentPermissionRaw) ?? .ask }
        set { agentPermissionRaw = newValue.rawValue }
    }

    /// The proxy configured on this host, without the password (that lives in the Keychain).
    public var ownProxy: HostProxyConfiguration? {
        guard let proxyKindRaw, !proxyHost.isEmpty, proxyPort > 0 else { return nil }
        return HostProxyConfiguration(kind: proxyKindRaw, host: proxyHost, port: proxyPort, username: proxyUsername.isEmpty ? nil : proxyUsername, ownerID: uuid)
    }

    /// The proxy that applies: the host's own, else the group's when inherited.
    public var effectiveProxy: HostProxyConfiguration? {
        ownProxy ?? (inheritsGroupProxy ? group?.proxy : nil)
    }

    /// The jump host that applies: the host's own, else the group's when inherited.
    public var effectiveJumpHost: SSHHost? {
        if let jumpHost { return jumpHost }
        guard inheritsGroupJumpHost, let group, let candidate = group.defaultJumpHost, candidate.uuid != uuid else { return nil }
        return candidate
    }

    /// The identity that applies: the host's own, else the group's default.
    public var effectiveIdentity: Identity? {
        identity ?? group?.defaultIdentity
    }

    /// `user@host` with the port appended when it is not the default 22.
    public var displayTarget: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}
