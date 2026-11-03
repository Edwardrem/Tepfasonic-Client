import CryptoKit
import Foundation
import TepfaCore

/// A user key pair for the Keys screen: generate, import, export, fingerprint,
/// and (for Ed25519/ECDSA) authenticate.
public struct SSHKeyPair: Sendable {
    public enum Material: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        case rsa(RSAPrivateKeyComponents)
    }

    public enum GenerationType: Sendable, Hashable, CaseIterable, Identifiable {
        case ed25519
        case ecdsaP256
        case ecdsaP384
        case ecdsaP521
        case rsa3072
        case rsa4096

        public var id: Self { self }

        public var displayName: String {
            switch self {
            case .ed25519: "Ed25519 (recommended)"
            case .ecdsaP256: "ECDSA P-256"
            case .ecdsaP384: "ECDSA P-384"
            case .ecdsaP521: "ECDSA P-521"
            case .rsa3072: "RSA 3072"
            case .rsa4096: "RSA 4096"
            }
        }
    }

    public let material: Material
    public let comment: String?

    public init(material: Material, comment: String? = nil) {
        self.material = material
        self.comment = comment
    }

    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, …
    public var keyType: String {
        switch material {
        case .ed25519: "ssh-ed25519"
        case .p256: "ecdsa-sha2-nistp256"
        case .p384: "ecdsa-sha2-nistp384"
        case .p521: "ecdsa-sha2-nistp521"
        case .rsa: "ssh-rsa"
        }
    }

    public var bits: Int {
        switch material {
        case .ed25519: 256
        case .p256: 256
        case .p384: 384
        case .p521: 521
        case .rsa(let components): components.bits
        }
    }

    /// SSH wire-format public key.
    public var publicKeyBlob: [UInt8] {
        var writer = SSHWireWriter()
        switch material {
        case .ed25519(let key):
            writer.writeString("ssh-ed25519")
            writer.writeString([UInt8](key.publicKey.rawRepresentation))
        case .p256(let key):
            writer.writeString("ecdsa-sha2-nistp256")
            writer.writeString("nistp256")
            writer.writeString([UInt8](key.publicKey.x963Representation))
        case .p384(let key):
            writer.writeString("ecdsa-sha2-nistp384")
            writer.writeString("nistp384")
            writer.writeString([UInt8](key.publicKey.x963Representation))
        case .p521(let key):
            writer.writeString("ecdsa-sha2-nistp521")
            writer.writeString("nistp521")
            writer.writeString([UInt8](key.publicKey.x963Representation))
        case .rsa(let components):
            return components.publicKeyBlob
        }
        return writer.bytes
    }

    /// `type base64 [comment]`, as written to `authorized_keys`.
    public var openSSHPublicKey: String {
        let line = "\(keyType) \(Data(publicKeyBlob).base64EncodedString())"
        if let comment, !comment.isEmpty { return line + " " + comment }
        return line
    }

    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(keyBlob: Data(publicKeyBlob))
    }

    /// The key usable for SSH authentication, or nil for RSA.
    public var authenticationKey: SSHPrivateKey? {
        switch material {
        case .ed25519(let key): SSHPrivateKey(ed25519: key, comment: comment)
        case .p256(let key): SSHPrivateKey(p256: key, comment: comment)
        case .p384(let key): SSHPrivateKey(p384: key, comment: comment)
        case .p521(let key): SSHPrivateKey(p521: key, comment: comment)
        case .rsa: nil
        }
    }

    public var canAuthenticate: Bool { authenticationKey != nil }

    // MARK: - Generation

    public static func generate(_ type: GenerationType, comment: String? = nil) throws -> SSHKeyPair {
        switch type {
        case .ed25519: SSHKeyPair(material: .ed25519(.init()), comment: comment)
        case .ecdsaP256: SSHKeyPair(material: .p256(.init()), comment: comment)
        case .ecdsaP384: SSHKeyPair(material: .p384(.init()), comment: comment)
        case .ecdsaP521: SSHKeyPair(material: .p521(.init()), comment: comment)
        case .rsa3072: SSHKeyPair(material: .rsa(try RSAPrivateKeyComponents.generate(bits: 3072)), comment: comment)
        case .rsa4096: SSHKeyPair(material: .rsa(try RSAPrivateKeyComponents.generate(bits: 4096)), comment: comment)
        }
    }

    // MARK: - Import

    /// Parses OpenSSH (`openssh-key-v1`), PEM (PKCS#8, PKCS#1, SEC1) and PuTTY `.ppk` keys.
    public static func parse(_ text: String, passphrase: String? = nil) throws -> SSHKeyPair {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try OpenSSHPrivateKeyParser.parse(text, passphrase: passphrase)
        }
        if text.hasPrefix("PuTTY-User-Key-File") {
            return try PPKParser.parse(text, passphrase: passphrase)
        }
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.contains("Proc-Type: 4,ENCRYPTED") {
            throw SSHKeyError.unsupportedFormat("encrypted PEM keys; convert with ssh-keygen -p -m RFC4716 or import the OpenSSH format")
        }
        if text.contains("BEGIN ") && text.contains("PRIVATE KEY-----") {
            return try PEMPrivateKeyParser.parse(text)
        }
        throw SSHKeyError.invalidFormat("unrecognised private key format")
    }

    public static func load(from url: URL, passphrase: String? = nil) throws -> SSHKeyPair {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SSHKeyError.unreadableFile(url.path)
        }
        return try parse(text, passphrase: passphrase)
    }

    // MARK: - Export

    /// The key in OpenSSH private key format, optionally encrypted with `aes256-ctr` + bcrypt.
    /// `rounds` is the bcrypt work factor (ssh-keygen's default is 16); only tests lower it.
    public func openSSHPrivateKey(passphrase: String? = nil, rounds: Int = 16) throws -> String {
        try OpenSSHPrivateKeyEncoder.encode(self, passphrase: passphrase, rounds: UInt32(max(1, rounds)))
    }
}
