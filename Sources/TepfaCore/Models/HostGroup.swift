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

    public init(uuid: UUID = UUID(), name: String, sortOrder: Int = 0, colorLabel: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.colorLabel = colorLabel
        self.hosts = []
    }
}
