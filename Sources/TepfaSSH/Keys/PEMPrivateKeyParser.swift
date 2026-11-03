import CryptoKit
import Foundation

/// PEM private keys: PKCS#8 (`PRIVATE KEY`), PKCS#1 (`RSA PRIVATE KEY`) and SEC1 (`EC PRIVATE KEY`).
enum PEMPrivateKeyParser {
    static let rsaOID = "1.2.840.113549.1.1.1"
    static let ecOID = "1.2.840.10045.2.1"
    static let ed25519OID = "1.3.101.112"

    static func parse(_ text: String) throws -> SSHKeyPair {
        if let der = PEM.body(text, label: "RSA PRIVATE KEY") {
            return SSHKeyPair(material: .rsa(try RSAPrivateKeyComponents.fromPKCS1([UInt8](der))))
        }
        if text.contains("BEGIN EC PRIVATE KEY") {
            return try parseEC(text)
        }
        if let der = PEM.body(text, label: "PRIVATE KEY") {
            return try parsePKCS8([UInt8](der), pem: text)
        }
        throw SSHKeyError.invalidFormat("unrecognised PEM private key")
    }

    private static func parseEC(_ text: String) throws -> SSHKeyPair {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return SSHKeyPair(material: .p256(key)) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return SSHKeyPair(material: .p384(key)) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return SSHKeyPair(material: .p521(key)) }
        throw SSHKeyError.invalidFormat("PEM EC key is not a named-curve P-256/384/521 key")
    }

    private static func parsePKCS8(_ der: [UInt8], pem: String) throws -> SSHKeyPair {
        var top = DERReader(der)
        var outer = try top.readSequence()
        _ = try outer.readUnsignedInteger() // version
        var algorithm = try outer.readSequence()
        let oid = try algorithm.readObjectIdentifier()
        let privateKey = try outer.read(.octetString)
        switch oid {
        case rsaOID:
            return SSHKeyPair(material: .rsa(try RSAPrivateKeyComponents.fromPKCS1(privateKey)))
        case ed25519OID:
            var inner = DERReader(privateKey)
            let seed = try inner.read(.octetString)
            return SSHKeyPair(material: .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))))
        case ecOID:
            return try parseEC(pem)
        default:
            throw SSHKeyError.unsupportedKeyType("PKCS#8 algorithm \(oid)")
        }
    }
}
