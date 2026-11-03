import Foundation
import SwiftData

/// Which way a saved forwarding rule points.
public enum PortForwardKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Listen on the Mac, connect to `targetHost:targetPort` from the server (`ssh -L`).
    case local
    /// Listen on the server, connect to `targetHost:targetPort` from the Mac (`ssh -R`).
    case remote
    /// A SOCKS5 proxy on the Mac that tunnels every connection through the server (`ssh -D`).
    case dynamic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "Dynamic (SOCKS5)"
        }
    }

    public var summary: String {
        switch self {
        case .local: "A port on this Mac reaches a service the server can see, such as a database on a private network."
        case .remote: "A port on the server reaches a service on this Mac, such as a local development server."
        case .dynamic: "A SOCKS5 proxy on this Mac; point a browser at it to tunnel through the server."
        }
    }

    public var usesTarget: Bool { self != .dynamic }
}

/// A saved port-forwarding rule tied to a host.
@Model
public final class PortForwardRule {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    /// Raw `PortForwardKind`. Use `kind`.
    public var kindRaw: String
    /// Address the listening side binds: `127.0.0.1` keeps it private; `0.0.0.0` (or `*`) opens it to the network.
    public var bindAddress: String
    /// Listening port; 0 asks for any free port.
    public var bindPort: Int
    /// Where accepted connections go (unused for dynamic rules).
    public var targetHost: String
    public var targetPort: Int
    /// Start as soon as the host connects.
    public var autoStart: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var host: SSHHost?

    public init(
        uuid: UUID = UUID(),
        name: String = "",
        kind: PortForwardKind = .local,
        bindAddress: String = "127.0.0.1",
        bindPort: Int,
        targetHost: String = "localhost",
        targetPort: Int = 0,
        autoStart: Bool = false,
        sortOrder: Int = 0,
        host: SSHHost? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.kindRaw = kind.rawValue
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.host = host
    }

    public var kind: PortForwardKind {
        get { PortForwardKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }

    /// `name`, or a description built from the ports when the name is empty.
    public var displayName: String {
        name.isEmpty ? PortForwardDescription.describe(kind: kind, bindAddress: bindAddress, bindPort: bindPort, targetHost: targetHost, targetPort: targetPort) : name
    }
}

/// Sendable copy of a rule for the forwarding engine.
public struct PortForwardDescriptor: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let kind: PortForwardKind
    public let bindAddress: String
    public let bindPort: Int
    public let targetHost: String
    public let targetPort: Int
    public let autoStart: Bool
    public let hostID: UUID?

    public init(id: UUID = UUID(), name: String = "", kind: PortForwardKind, bindAddress: String = "127.0.0.1", bindPort: Int, targetHost: String = "localhost", targetPort: Int = 0, autoStart: Bool = false, hostID: UUID?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
        self.hostID = hostID
    }

    @MainActor
    public init(_ rule: PortForwardRule) {
        self.init(id: rule.uuid, name: rule.name, kind: rule.kind, bindAddress: rule.bindAddress, bindPort: rule.bindPort, targetHost: rule.targetHost, targetPort: rule.targetPort, autoStart: rule.autoStart, hostID: rule.host?.uuid)
    }

    public var displayName: String {
        name.isEmpty ? PortForwardDescription.describe(kind: kind, bindAddress: bindAddress, bindPort: bindPort, targetHost: targetHost, targetPort: targetPort) : name
    }

    public var summary: String {
        PortForwardDescription.describe(kind: kind, bindAddress: bindAddress, bindPort: bindPort, targetHost: targetHost, targetPort: targetPort)
    }

    /// The bind address as the SSH server or socket API wants it (`*` becomes `0.0.0.0`).
    public var effectiveBindAddress: String {
        let trimmed = bindAddress.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "localhost" { return "127.0.0.1" }
        if trimmed == "*" { return "0.0.0.0" }
        return trimmed
    }
}

public enum PortForwardDescription {
    public static func describe(kind: PortForwardKind, bindAddress: String, bindPort: Int, targetHost: String, targetPort: Int) -> String {
        let bind = bindAddress.isEmpty || bindAddress == "127.0.0.1" || bindAddress == "localhost" ? "localhost" : bindAddress
        switch kind {
        case .local: return "\(bind):\(bindPort) → \(targetHost):\(targetPort)"
        case .remote: return "server \(bind):\(bindPort) → \(targetHost):\(targetPort) on this Mac"
        case .dynamic: return "SOCKS5 on \(bind):\(bindPort)"
        }
    }

    /// Parses `ssh`-style specs: `8080:localhost:80`, `127.0.0.1:8080:db:5432`, `1080` (dynamic).
    public static func parse(_ text: String, kind: PortForwardKind) -> (bindAddress: String, bindPort: Int, targetHost: String, targetPort: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func port(_ value: String) -> Int? {
            guard let number = Int(value), (0...65535).contains(number) else { return nil }
            return number
        }
        switch (kind, parts.count) {
        case (.dynamic, 1):
            guard let bind = port(parts[0]) else { return nil }
            return ("127.0.0.1", bind, "", 0)
        case (.dynamic, 2):
            guard let bind = port(parts[1]) else { return nil }
            return (parts[0], bind, "", 0)
        case (_, 3):
            guard let bind = port(parts[0]), let target = port(parts[2]), !parts[1].isEmpty else { return nil }
            return ("127.0.0.1", bind, parts[1], target)
        case (_, 4):
            guard let bind = port(parts[1]), let target = port(parts[3]), !parts[2].isEmpty else { return nil }
            return (parts[0], bind, parts[2], target)
        default:
            return nil
        }
    }
}
