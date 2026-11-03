import CryptoKit
import Foundation

/// OpenBSD `bcrypt_pbkdf`, the KDF used by encrypted `openssh-key-v1` files.
enum BcryptPBKDF {
    static func derive(password: [UInt8], salt: [UInt8], keyLength: Int, rounds: Int) throws -> [UInt8] {
        guard rounds >= 1, keyLength > 0, keyLength <= 1024, !salt.isEmpty else {
            throw SSHKeyError.invalidFormat("invalid bcrypt_pbkdf parameters")
        }
        let passwordHash = Array(SHA512.hash(data: password))
        var key = [UInt8](repeating: 0, count: keyLength)
        let stride = (keyLength + 32 - 1) / 32
        var amount = (keyLength + stride - 1) / stride
        var remaining = keyLength
        var count: UInt32 = 1

        while remaining > 0 {
            var countedSalt = salt
            countedSalt.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
            var saltHash = Array(SHA512.hash(data: countedSalt))
            var block = bcryptHash(passwordHash, saltHash)
            var output = block
            for _ in 1..<rounds {
                saltHash = Array(SHA512.hash(data: block))
                block = bcryptHash(passwordHash, saltHash)
                for i in 0..<output.count { output[i] ^= block[i] }
            }
            amount = min(amount, remaining)
            var written = 0
            for i in 0..<amount {
                let destination = i * stride + Int(count - 1)
                guard destination < keyLength else { break }
                key[destination] = output[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return key
    }

    /// `bcrypt_hash`: 32 bytes from a SHA-512 password hash and SHA-512 salt hash.
    private static func bcryptHash(_ passwordHash: [UInt8], _ saltHash: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(data: saltHash, key: passwordHash)
        for _ in 0..<64 {
            state.expand0State(key: saltHash)
            state.expand0State(key: passwordHash)
        }
        let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var words = [UInt32](repeating: 0, count: 8)
        var position = 0
        for i in 0..<8 {
            words[i] = Blowfish.stream2word(magic, &position)
        }
        for _ in 0..<64 {
            state.encrypt(&words)
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i] = UInt8(words[i] & 0xFF)
            out[4 * i + 1] = UInt8((words[i] >> 8) & 0xFF)
            out[4 * i + 2] = UInt8((words[i] >> 16) & 0xFF)
            out[4 * i + 3] = UInt8((words[i] >> 24) & 0xFF)
        }
        return out
    }
}
