import Foundation

/// A proxy as stored on a host or group: everything but the password, which
/// the Keychain holds under `SecretAccount.proxyPassword(ownerID)`.
public struct HostProxyConfiguration: Sendable, Hashable, Codable {
    /// `http` or `socks5`.
    public var kind: String
    public var host: String
    public var port: Int
    public var username: String?
    /// The host or group that owns the proxy (and its Keychain password).
    public var ownerID: UUID

    public init(kind: String, host: String, port: Int, username: String? = nil, ownerID: UUID) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.ownerID = ownerID
    }

    public var displayTarget: String {
        "\(kind == "socks5" ? "SOCKS5" : "HTTP") \(host):\(port)"
    }
}
