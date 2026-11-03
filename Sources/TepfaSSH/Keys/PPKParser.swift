import CommonCrypto
import CryptoKit
import Foundation
import TepfaCore

/// PuTTY private key files, versions 2 and 3, plain or aes256-cbc. Version 2
/// derives the key with SHA-1; version 3 with Argon2 (id, i or d).
enum PPKParser {
    static func parse(_ text: String, passphrase: String?) throws -> SSHKeyPair {
        var fields: [String: String] = [:]
        var publicLines: [String] = []
        var privateLines: [String] = []
        var version = 0
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)[...]

        func take(_ count: Int) throws -> [String] {
            guard lines.count >= count else { throw SSHKeyError.invalidFormat("truncated .ppk file") }
            let block = Array(lines.prefix(count))
            lines = lines.dropFirst(count)
            return block
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("PuTTY-User-Key-File-") {
                version = Int(key.dropFirst("PuTTY-User-Key-File-".count)) ?? 0
                fields["Type"] = value
            } else if key == "Public-Lines" {
                publicLines = try take(Int(value) ?? 0)
            } else if key == "Private-Lines" {
                privateLines = try take(Int(value) ?? 0)
            } else {
                fields[key] = value
            }
        }
        guard version == 2 || version == 3 else {
            throw SSHKeyError.unsupportedFormat(".ppk version \(version)")
        }
        guard let type = fields["Type"], let publicBlob = Data(base64Encoded: publicLines.joined()),
              var privateBlob = Data(base64Encoded: privateLines.joined()).map({ [UInt8]($0) }) else {
            throw SSHKeyError.invalidFormat("malformed .ppk file")
        }
        let encryption = fields["Encryption"] ?? "none"
        let comment = fields["Comment"]

        // Version 3 MAC key: empty when unencrypted, else the tail of the Argon2 output.
        var v3MacKey: [UInt8] = []

        if encryption != "none" {
            guard encryption == "aes256-cbc" else { throw SSHKeyError.unsupportedFormat(".ppk encryption \(encryption)") }
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.passphraseRequired }
            if version == 2 {
                let key = Array(Insecure.SHA1.hash(data: [0, 0, 0, 0] + Array(passphrase.utf8))) + Array(Insecure.SHA1.hash(data: [0, 0, 0, 1] + Array(passphrase.utf8)))
                privateBlob = try AESCipher.decrypt(privateBlob, key: Array(key[0..<32]), iv: [UInt8](repeating: 0, count: 16), mode: .cbc)
            } else {
                let derived = try argon2Material(fields: fields, passphrase: passphrase)
                privateBlob = try AESCipher.decrypt(privateBlob, key: Array(derived[0..<32]), iv: Array(derived[32..<48]), mode: .cbc)
                v3MacKey = Array(derived[48..<80])
            }
        }

        if let mac = fields["Private-MAC"] {
            var macData = SSHWireWriter()
            macData.writeString(type)
            macData.writeString(encryption)
            macData.writeString(comment ?? "")
            macData.writeString([UInt8](publicBlob))
            macData.writeString(privateBlob)
            let expectedHex: String
            if version == 2 {
                let macKey = Insecure.SHA1.hash(data: Array("putty-private-key-file-mac-key".utf8) + Array((encryption == "none" ? "" : (passphrase ?? "")).utf8))
                expectedHex = HMAC<Insecure.SHA1>.authenticationCode(for: macData.bytes, using: SymmetricKey(data: Array(macKey))).map { String(format: "%02x", $0) }.joined()
            } else {
                expectedHex = HMAC<SHA256>.authenticationCode(for: macData.bytes, using: SymmetricKey(data: v3MacKey)).map { String(format: "%02x", $0) }.joined()
            }
            guard expectedHex == mac.lowercased() else {
                throw encryption == "none" ? SSHKeyError.invalidFormat(".ppk MAC mismatch; the file may be corrupt") : SSHKeyError.wrongPassphrase
            }
        }

        var publicReader = SSHWireReader(publicBlob)
        let publicType = try publicReader.readUTF8String()
        guard publicType == type else { throw SSHKeyError.invalidFormat(".ppk key type mismatch") }
        var privateReader = SSHWireReader(privateBlob)

        switch type {
        case "ssh-ed25519":
            let seed = try privateReader.readString()
            return SSHKeyPair(material: .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))), comment: comment)
        case "ecdsa-sha2-nistp256":
            return SSHKeyPair(material: .p256(try P256.Signing.PrivateKey(rawRepresentation: OpenSSHPrivateKeyParser.fixedWidth(try privateReader.readString(), 32))), comment: comment)
        case "ecdsa-sha2-nistp384":
            return SSHKeyPair(material: .p384(try P384.Signing.PrivateKey(rawRepresentation: OpenSSHPrivateKeyParser.fixedWidth(try privateReader.readString(), 48))), comment: comment)
        case "ecdsa-sha2-nistp521":
            return SSHKeyPair(material: .p521(try P521.Signing.PrivateKey(rawRepresentation: OpenSSHPrivateKeyParser.fixedWidth(try privateReader.readString(), 66))), comment: comment)
        case "ssh-rsa":
            let e = try publicReader.readString()
            let n = try publicReader.readString()
            let d = try privateReader.readString()
            let p = try privateReader.readString()
            let q = try privateReader.readString()
            let iqmp = try privateReader.readString()
            let components = RSAPrivateKeyComponents(
                modulus: OpenSSHPrivateKeyParser.strip(n), publicExponent: OpenSSHPrivateKeyParser.strip(e),
                privateExponent: OpenSSHPrivateKeyParser.strip(d), prime1: OpenSSHPrivateKeyParser.strip(p),
                prime2: OpenSSHPrivateKeyParser.strip(q), exponent1: [], exponent2: [], coefficient: OpenSSHPrivateKeyParser.strip(iqmp))
            return SSHKeyPair(material: .rsa(components), comment: comment)
        default:
            throw SSHKeyError.unsupportedKeyType(type)
        }
    }

    /// Version 3: Argon2 over the passphrase gives 80 bytes: AES key, IV and MAC key.
    private static func argon2Material(fields: [String: String], passphrase: String) throws -> [UInt8] {
        let variant: Argon2.Variant
        switch (fields["Key-Derivation"] ?? "").lowercased() {
        case "argon2id": variant = .id
        case "argon2i": variant = .i
        case "argon2d": variant = .d
        default: throw SSHKeyError.unsupportedFormat(".ppk key derivation \(fields["Key-Derivation"] ?? "missing")")
        }
        guard let memory = fields["Argon2-Memory"].flatMap({ UInt32($0) }),
              let passes = fields["Argon2-Passes"].flatMap({ UInt32($0) }),
              let parallelism = fields["Argon2-Parallelism"].flatMap({ UInt32($0) }),
              let salt = fields["Argon2-Salt"].flatMap(hexBytes) else {
            throw SSHKeyError.invalidFormat(".ppk Argon2 parameters are missing or malformed")
        }
        do {
            return try Argon2.hash(
                password: Array(passphrase.utf8), salt: salt,
                parameters: Argon2.Parameters(variant: variant, memoryKiB: memory, iterations: passes, parallelism: parallelism),
                outputLength: 80)
        } catch {
            throw SSHKeyError.invalidFormat(".ppk Argon2 parameters are out of range")
        }
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        guard characters.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            out.append(byte)
            index += 2
        }
        return out
    }
}
