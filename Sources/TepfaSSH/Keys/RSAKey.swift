import Foundation
import Security

/// RSA private key components (big-endian magnitudes). Tepfasonic can generate,
/// import, export and push RSA keys, but cannot authenticate with them because
/// SwiftNIO SSH has no RSA support.
public struct RSAPrivateKeyComponents: Sendable, Hashable {
    public var modulus: [UInt8]        // n
    public var publicExponent: [UInt8] // e
    public var privateExponent: [UInt8] // d
    public var prime1: [UInt8]         // p
    public var prime2: [UInt8]         // q
    public var exponent1: [UInt8]      // dP (may be empty when unknown)
    public var exponent2: [UInt8]      // dQ (may be empty when unknown)
    public var coefficient: [UInt8]    // qInv (iqmp)

    public var bits: Int {
        var leading = modulus[...]
        while leading.first == 0 { leading = leading.dropFirst() }
        guard let first = leading.first else { return 0 }
        return (leading.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    /// Parses a PKCS#1 `RSAPrivateKey` structure.
    public static func fromPKCS1(_ der: [UInt8]) throws -> RSAPrivateKeyComponents {
        var outer = DERReader(der)
        var sequence = try outer.readSequence()
        let version = try sequence.readUnsignedInteger()
        guard version == [0] else { throw SSHKeyError.invalidFormat("unsupported RSA key version") }
        return RSAPrivateKeyComponents(
            modulus: try sequence.readUnsignedInteger(),
            publicExponent: try sequence.readUnsignedInteger(),
            privateExponent: try sequence.readUnsignedInteger(),
            prime1: try sequence.readUnsignedInteger(),
            prime2: try sequence.readUnsignedInteger(),
            exponent1: try sequence.readUnsignedInteger(),
            exponent2: try sequence.readUnsignedInteger(),
            coefficient: try sequence.readUnsignedInteger())
    }

    /// Generates a key with the Security framework.
    public static func generate(bits: Int) throws -> RSAPrivateKeyComponents {
        guard (2048...8192).contains(bits), bits % 8 == 0 else {
            throw SSHKeyError.invalidFormat("RSA key size must be between 2048 and 8192 bits")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw SSHKeyError.invalidFormat("RSA generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
        }
        return try fromPKCS1([UInt8](data))
    }

    /// SSH wire public key: `string "ssh-rsa", mpint e, mpint n`.
    public var publicKeyBlob: [UInt8] {
        var writer = SSHWireWriter()
        writer.writeString("ssh-rsa")
        writer.writeMPInt(publicExponent)
        writer.writeMPInt(modulus)
        return writer.bytes
    }
}
