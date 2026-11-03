import Foundation
import NIOSSH
import TepfaCore

/// The host key a server presented during the handshake.
public struct HostKeyInfo: Sendable, Hashable {
    /// e.g. `ssh-ed25519`
    public let keyType: String
    /// `type base64`, suitable for `KnownHostsStore`.
    public let openSSHPublicKey: String
    /// `SHA256:…`, as `ssh -v` and `ssh-keygen -lf` print it.
    public let fingerprintSHA256: String

    public init(keyType: String, openSSHPublicKey: String, fingerprintSHA256: String) {
        self.keyType = keyType
        self.openSSHPublicKey = openSSHPublicKey
        self.fingerprintSHA256 = fingerprintSHA256
    }

    init(_ key: NIOSSHPublicKey) {
        let line = String(openSSHPublicKey: key)
        keyType = String(line.split(separator: " ").first ?? "")
        openSSHPublicKey = line
        fingerprintSHA256 = HostKeyFingerprint.sha256(openSSHPublicKey: line) ?? ""
    }
}

/// Decides whether to trust a server's host key. Called once per connection,
/// off the main actor; implementations may prompt the user.
public protocol HostKeyVerifier: Sendable {
    func verify(hostKey: HostKeyInfo, host: String, port: Int) async -> Bool
}

public struct ClosureHostKeyVerifier: HostKeyVerifier {
    private let handler: @Sendable (HostKeyInfo, String, Int) async -> Bool

    public init(_ handler: @escaping @Sendable (HostKeyInfo, String, Int) async -> Bool) {
        self.handler = handler
    }

    public func verify(hostKey: HostKeyInfo, host: String, port: Int) async -> Bool {
        await handler(hostKey, host, port)
    }
}

/// Trusts every host key. Only for tests against a throwaway server.
public struct InsecureAcceptAllHostKeys: HostKeyVerifier {
    public init() {}
    public func verify(hostKey: HostKeyInfo, host: String, port: Int) async -> Bool { true }
}
