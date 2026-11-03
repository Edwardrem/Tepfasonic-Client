import CryptoKit
import Foundation

/// Parses the `openssh-key-v1` private key container (PROTOCOL.key in OpenSSH),
/// including keys encrypted with bcrypt + AES.
enum OpenSSHPrivateKeyParser {
    static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    static let magic: [UInt8] = Array("openssh-key-v1".utf8) + [0]

    struct Cipher {
        let keyLength: Int
        let mode: AESCipher.Mode

        static func named(_ name: String) -> Cipher? {
            switch name {
            case "aes128-ctr": Cipher(keyLength: 16, mode: .ctr)
            case "aes192-ctr": Cipher(keyLength: 24, mode: .ctr)
            case "aes256-ctr": Cipher(keyLength: 32, mode: .ctr)
            case "aes128-cbc": Cipher(keyLength: 16, mode: .cbc)
            case "aes192-cbc": Cipher(keyLength: 24, mode: .cbc)
            case "aes256-cbc": Cipher(keyLength: 32, mode: .cbc)
            default: nil
            }
        }
    }

    static func parse(_ text: String, passphrase: String?) throws -> SSHKeyPair {
        guard let blob = pemBody(text, begin: beginMarker, end: endMarker) else {
            throw SSHKeyError.invalidFormat("missing or malformed OPENSSH PRIVATE KEY armor")
        }

        var reader = SSHWireReader(blob)
        try reader.expectPrefix(magic, description: "openssh-key-v1 magic")
        let cipherName = try reader.readUTF8String()
        let kdfName = try reader.readUTF8String()
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw SSHKeyError.invalidFormat("expected exactly one key, found \(keyCount)")
        }
        _ = try reader.readString() // public key blob, re-derived from the private part below
        var privateSection = try reader.readString()

        if cipherName != "none" {
            guard let cipher = Cipher.named(cipherName) else {
                throw SSHKeyError.unsupportedFormat("keys encrypted with \(cipherName)")
            }
            guard kdfName == "bcrypt" else {
                throw SSHKeyError.unsupportedFormat("keys using the \(kdfName) KDF")
            }
            guard let passphrase, !passphrase.isEmpty else {
                throw SSHKeyError.passphraseRequired
            }
            var options = SSHWireReader(kdfOptions)
            let salt = try options.readString()
            let rounds = try options.readUInt32()
            let derived = try BcryptPBKDF.derive(password: Array(passphrase.utf8), salt: salt, keyLength: cipher.keyLength + 16, rounds: Int(rounds))
            let key = Array(derived[0..<cipher.keyLength])
            let iv = Array(derived[cipher.keyLength..<cipher.keyLength + 16])
            privateSection = try AESCipher.decrypt(privateSection, key: key, iv: iv, mode: cipher.mode)
        }

        var section = SSHWireReader(privateSection)
        let check1 = try section.readUInt32()
        let check2 = try section.readUInt32()
        guard check1 == check2 else {
            if cipherName != "none" { throw SSHKeyError.wrongPassphrase }
            throw SSHKeyError.invalidFormat("check integers differ; the key file may be corrupt")
        }

        let keyType = try section.readUTF8String()
        switch keyType {
        case "ssh-ed25519":
            _ = try section.readString() // public key (32 bytes)
            let secret = try section.readString() // 64 bytes: seed || public key
            guard secret.count == 64 else {
                throw SSHKeyError.invalidFormat("ed25519 private key should be 64 bytes, found \(secret.count)")
            }
            let comment = try section.readUTF8String()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(secret[0..<32]))
            return SSHKeyPair(material: .ed25519(key), comment: comment)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = try section.readUTF8String()
            _ = try section.readString() // public point
            let scalar = try section.readString() // mpint
            let comment = try section.readUTF8String()
            switch curve {
            case "nistp256":
                return SSHKeyPair(material: .p256(try P256.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 32))), comment: comment)
            case "nistp384":
                return SSHKeyPair(material: .p384(try P384.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 48))), comment: comment)
            case "nistp521":
                return SSHKeyPair(material: .p521(try P521.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 66))), comment: comment)
            default:
                throw SSHKeyError.unsupportedKeyType("\(keyType) (\(curve))")
            }

        case "ssh-rsa":
            let n = try section.readString()
            let e = try section.readString()
            let d = try section.readString()
            let iqmp = try section.readString()
            let p = try section.readString()
            let q = try section.readString()
            let comment = try section.readUTF8String()
            let components = RSAPrivateKeyComponents(
                modulus: strip(n), publicExponent: strip(e), privateExponent: strip(d),
                prime1: strip(p), prime2: strip(q), exponent1: [], exponent2: [], coefficient: strip(iqmp))
            return SSHKeyPair(material: .rsa(components), comment: comment)

        default:
            // ssh-dss, sk-* (FIDO) and certificates all land here.
            throw SSHKeyError.unsupportedKeyType(keyType)
        }
    }

    /// Base64 body between PEM markers, ignoring whitespace.
    static func pemBody(_ text: String, begin: String, end: String) -> Data? {
        guard let beginRange = text.range(of: begin), let endRange = text.range(of: end), beginRange.upperBound <= endRange.lowerBound else {
            return nil
        }
        let body = text[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body))
    }

    /// Strips an mpint's sign byte / leading zeros and left-pads to the curve's scalar width.
    static func fixedWidth(_ mpint: [UInt8], _ width: Int) throws -> Data {
        var bytes = mpint[...]
        while bytes.count > width, bytes.first == 0 {
            bytes = bytes.dropFirst()
        }
        guard bytes.count <= width else {
            throw SSHKeyError.invalidFormat("ECDSA scalar is \(bytes.count) bytes, expected at most \(width)")
        }
        return Data(repeating: 0, count: width - bytes.count) + Data(bytes)
    }

    static func strip(_ mpint: [UInt8]) -> [UInt8] {
        var value = mpint[...]
        while value.count > 1, value.first == 0 { value = value.dropFirst() }
        return Array(value)
    }
}
