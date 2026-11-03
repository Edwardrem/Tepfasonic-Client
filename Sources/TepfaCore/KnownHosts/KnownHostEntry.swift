import Foundation

/// A host key the user has chosen to trust.
public struct KnownHostEntry: Codable, Hashable, Sendable, Identifiable {
    public var host: String
    public var port: Int
    /// e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`
    public var keyType: String
    /// OpenSSH public key line without comment: `type base64`.
    public var publicKey: String
    public var fingerprintSHA256: String
    public var addedAt: Date

    public init(host: String, port: Int, keyType: String, publicKey: String, fingerprintSHA256: String, addedAt: Date = .now) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.publicKey = publicKey
        self.fingerprintSHA256 = fingerprintSHA256
        self.addedAt = addedAt
    }

    public var id: String { Self.key(host: host, port: port, keyType: keyType) }

    static func key(host: String, port: Int, keyType: String) -> String {
        "\(host.lowercased()):\(port):\(keyType)"
    }
}

/// Outcome of checking a presented host key against the store.
public enum HostKeyVerdict: Hashable, Sendable {
    /// The key matches what we saved earlier.
    case known
    /// We have never seen a key of this type for this host and port.
    case unknown
    /// We saved a different key of this type for this host and port. Could be a
    /// reinstall, could be an attack: the user must decide.
    case changed(previous: KnownHostEntry)
}
