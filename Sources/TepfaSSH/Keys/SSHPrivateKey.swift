import CryptoKit
import Foundation
import NIOSSH
import TepfaCore

/// A user private key usable for public-key authentication.
///
/// SwiftNIO SSH (and therefore Tepfasonic) supports Ed25519 and ECDSA keys.
/// RSA keys are rejected with `SSHKeyError.unsupportedKeyType`.
public struct SSHPrivateKey: Sendable {
    public enum KeyType: String, Sendable, CaseIterable {
        case ed25519 = "ssh-ed25519"
        case ecdsaP256 = "ecdsa-sha2-nistp256"
        case ecdsaP384 = "ecdsa-sha2-nistp384"
        case ecdsaP521 = "ecdsa-sha2-nistp521"
    }

    let nioKey: NIOSSHPrivateKey
    public let keyType: KeyType
    public let comment: String?

    public init(ed25519 key: Curve25519.Signing.PrivateKey, comment: String? = nil) {
        nioKey = NIOSSHPrivateKey(ed25519Key: key)
        keyType = .ed25519
        self.comment = comment
    }

    public init(p256 key: P256.Signing.PrivateKey, comment: String? = nil) {
        nioKey = NIOSSHPrivateKey(p256Key: key)
        keyType = .ecdsaP256
        self.comment = comment
    }

    public init(p384 key: P384.Signing.PrivateKey, comment: String? = nil) {
        nioKey = NIOSSHPrivateKey(p384Key: key)
        keyType = .ecdsaP384
        self.comment = comment
    }

    public init(p521 key: P521.Signing.PrivateKey, comment: String? = nil) {
        nioKey = NIOSSHPrivateKey(p521Key: key)
        keyType = .ecdsaP521
        self.comment = comment
    }

    /// OpenSSH public key line without comment: `type base64`.
    public var openSSHPublicKey: String {
        String(openSSHPublicKey: nioKey.publicKey)
    }

    /// `SHA256:…` fingerprint, as printed by `ssh-keygen -lf`.
    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(openSSHPublicKey: openSSHPublicKey) ?? ""
    }

    /// Loads a key from disk. `~` is expanded.
    public static func load(from url: URL, passphrase: String? = nil) throws -> SSHPrivateKey {
        try authenticationKey(from: try SSHKeyPair.load(from: url, passphrase: passphrase))
    }

    public static func load(fromPath path: String, passphrase: String? = nil) throws -> SSHPrivateKey {
        try load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), passphrase: passphrase)
    }

    /// Parses an OpenSSH, PEM or PuTTY private key and returns it if it can authenticate.
    public static func parse(_ text: String, passphrase: String? = nil) throws -> SSHPrivateKey {
        try authenticationKey(from: try SSHKeyPair.parse(text, passphrase: passphrase))
    }

    private static func authenticationKey(from pair: SSHKeyPair) throws -> SSHPrivateKey {
        guard let key = pair.authenticationKey else {
            throw SSHKeyError.cannotAuthenticate(pair.keyType)
        }
        return key
    }
}
