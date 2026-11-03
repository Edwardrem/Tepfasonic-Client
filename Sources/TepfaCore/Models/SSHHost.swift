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

    /// `user@host` with the port appended when it is not the default 22.
    public var displayTarget: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}
