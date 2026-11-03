import Foundation
import Testing
@testable import TepfaSSH

@Suite struct BlowfishTests {
    /// Bruce Schneier's published ECB test vectors.
    @Test func matchesReferenceVectors() {
        let vectors: [(key: UInt64, plain: UInt64, cipher: UInt64)] = [
            (0x0000000000000000, 0x0000000000000000, 0x4EF997456198DD78),
            (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0x51866FD5B85ECB8A),
            (0x0123456789ABCDEF, 0x1111111111111111, 0x61F9C3802281B096),
            (0xFEDCBA9876543210, 0x0123456789ABCDEF, 0x0ACEAB0FC6A0A28D),
        ]
        for vector in vectors {
            var state = Blowfish()
            state.expand0State(key: bytes(vector.key))
            var words = [UInt32(vector.plain >> 32), UInt32(vector.plain & 0xFFFF_FFFF)]
            state.encrypt(&words)
            let result = UInt64(words[0]) << 32 | UInt64(words[1])
            #expect(result == vector.cipher, "key \(String(vector.key, radix: 16))")
        }
    }

    @Test func bcryptPBKDFIsDeterministicAndStretches() throws {
        let a = try BcryptPBKDF.derive(password: Array("secret".utf8), salt: Array("saltsalt".utf8), keyLength: 48, rounds: 2)
        let b = try BcryptPBKDF.derive(password: Array("secret".utf8), salt: Array("saltsalt".utf8), keyLength: 48, rounds: 2)
        let c = try BcryptPBKDF.derive(password: Array("secret!".utf8), salt: Array("saltsalt".utf8), keyLength: 48, rounds: 2)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 48)
        #expect(Set(a).count > 8)
    }

    @Test func aesRoundTrip() throws {
        let key = [UInt8](repeating: 7, count: 32)
        let iv = [UInt8](repeating: 9, count: 16)
        let plain = Array("The quick brown fox jumps over the lazy dog!!!!!".utf8)
        for mode in [AESCipher.Mode.ctr, .cbc] {
            let encrypted = try AESCipher.encrypt(plain, key: key, iv: iv, mode: mode)
            #expect(encrypted != plain)
            #expect(try AESCipher.decrypt(encrypted, key: key, iv: iv, mode: mode) == plain)
        }
    }

    private func bytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (56 - 8 * UInt64($0))) & 0xFF) }
    }
}
