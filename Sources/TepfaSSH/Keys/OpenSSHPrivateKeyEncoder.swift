import CryptoKit
import Foundation

/// Writes `openssh-key-v1` files, unencrypted or with `aes256-ctr` + bcrypt (16 rounds),
/// matching what `ssh-keygen` produces.
enum OpenSSHPrivateKeyEncoder {
    static let defaultRounds: UInt32 = 16

    static func encode(_ pair: SSHKeyPair, passphrase: String?, rounds: UInt32 = defaultRounds) throws -> String {
        var privateSection = SSHWireWriter()
        let check = UInt32.random(in: UInt32.min...UInt32.max)
        privateSection.writeUInt32(check)
        privateSection.writeUInt32(check)
        privateSection.writeString(pair.keyType)
        switch pair.material {
        case .ed25519(let key):
            let publicKey = [UInt8](key.publicKey.rawRepresentation)
            privateSection.writeString(publicKey)
            privateSection.writeString([UInt8](key.rawRepresentation) + publicKey)
        case .p256(let key):
            privateSection.writeString("nistp256")
            privateSection.writeString([UInt8](key.publicKey.x963Representation))
            privateSection.writeMPInt([UInt8](key.rawRepresentation))
        case .p384(let key):
            privateSection.writeString("nistp384")
            privateSection.writeString([UInt8](key.publicKey.x963Representation))
            privateSection.writeMPInt([UInt8](key.rawRepresentation))
        case .p521(let key):
            privateSection.writeString("nistp521")
            privateSection.writeString([UInt8](key.publicKey.x963Representation))
            privateSection.writeMPInt([UInt8](key.rawRepresentation))
        case .rsa(let components):
            privateSection.writeMPInt(components.modulus)
            privateSection.writeMPInt(components.publicExponent)
            privateSection.writeMPInt(components.privateExponent)
            privateSection.writeMPInt(components.coefficient)
            privateSection.writeMPInt(components.prime1)
            privateSection.writeMPInt(components.prime2)
        }
        privateSection.writeString(pair.comment ?? "")

        let blockSize = passphrase == nil ? 8 : 16
        var padding: UInt8 = 1
        var body = privateSection.bytes
        while body.count % blockSize != 0 {
            body.append(padding)
            padding &+= 1
        }

        var file = SSHWireWriter()
        file.writeBytes(OpenSSHPrivateKeyParser.magic)
        if let passphrase, !passphrase.isEmpty {
            var salt = [UInt8](repeating: 0, count: 16)
            for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
            let rounds = max(1, rounds)
            let derived = try BcryptPBKDF.derive(password: Array(passphrase.utf8), salt: salt, keyLength: 48, rounds: Int(rounds))
            body = try AESCipher.encrypt(body, key: Array(derived[0..<32]), iv: Array(derived[32..<48]), mode: .ctr)
            var options = SSHWireWriter()
            options.writeString(salt)
            options.writeUInt32(rounds)
            file.writeString("aes256-ctr")
            file.writeString("bcrypt")
            file.writeString(options.bytes)
        } else {
            file.writeString("none")
            file.writeString("none")
            file.writeString([UInt8]())
        }
        file.writeUInt32(1)
        file.writeString(pair.publicKeyBlob)
        file.writeString(body)

        return PEM.encode(file.bytes, label: "OPENSSH PRIVATE KEY")
    }
}
