import Foundation
import SwiftData

/// A folder of hosts in the sidebar.
@Model
public final class HostGroup {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date
    /// Hex colour (`#RRGGBB`) inherited by hosts in the group that set none.
    public var colorLabel: String?

    @Relationship(deleteRule: .nullify, inverse: \SSHHost.group)
    public var hosts: [SSHHost]
    /// Identity used by hosts in the group that have none of their own.
    public var defaultIdentity: Identity?
    /// Bastion used by hosts in the group that have none of their own (and inherit it).
    public var defaultJumpHost: SSHHost?
    /// Raw `ProxySettings.Kind`; nil means no group proxy.
    public var proxyKindRaw: String?
    public var proxyHost: String = ""
    public var proxyPort: Int = 0
    public var proxyUsername: String = ""
    /// Terminal colour scheme id inherited by hosts in the group that set none.
    public var themeID: String?
    public var fontName: String?
    public var fontSize: Double?

    /// The group's proxy, without the password (that lives in the Keychain).
    public var proxy: HostProxyConfiguration? {
        guard let proxyKindRaw, !proxyHost.isEmpty, proxyPort > 0 else { return nil }
        return HostProxyConfiguration(kind: proxyKindRaw, host: proxyHost, port: proxyPort, username: proxyUsername.isEmpty ? nil : proxyUsername, ownerID: uuid)
    }

    public init(uuid: UUID = UUID(), name: String, sortOrder: Int = 0, colorLabel: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.colorLabel = colorLabel
        self.hosts = []
    }
}
