import Foundation
import Testing
@testable import TepfaCore

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@Suite struct BLAKE2bTests {
    @Test func matchesKnownDigests() {
        #expect(hex(BLAKE2b.hash([], outputLength: 64)) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        #expect(hex(BLAKE2b.hash(Array("abc".utf8), outputLength: 64)) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    }

    @Test func handlesMultiBlockInputAndShortOutputs() {
        let input = Array(repeating: UInt8(0x61), count: 300)
        let full = BLAKE2b.hash(input, outputLength: 64)
        #expect(full.count == 64)
        // Short outputs are a different hash, not a truncation.
        #expect(BLAKE2b.hash(input, outputLength: 32) != Array(full.prefix(32)))
        var streamed = BLAKE2b(outputLength: 64)
        streamed.update(input[..<100])
        streamed.update(input[100...])
        #expect(streamed.finalize() == full)
    }
}

@Suite struct Argon2Tests {
    private let password = [UInt8](repeating: 0x01, count: 32)
    private let salt = [UInt8](repeating: 0x02, count: 16)
    private let secret = [UInt8](repeating: 0x03, count: 8)
    private let associated = [UInt8](repeating: 0x04, count: 12)

    private func tag(_ variant: Argon2.Variant) throws -> String {
        hex(try Argon2.hash(
            password: password, salt: salt, secret: secret, associatedData: associated,
            parameters: Argon2.Parameters(variant: variant, memoryKiB: 32, iterations: 3, parallelism: 4),
            outputLength: 32))
    }

    @Test func rfc9106Argon2dVector() throws {
        #expect(try tag(.d) == "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb")
    }

    @Test func rfc9106Argon2iVector() throws {
        #expect(try tag(.i) == "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8")
    }

    @Test func rfc9106Argon2idVector() throws {
        #expect(try tag(.id) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    @Test func singleLaneLongOutputAndParameterChecks() throws {
        let out = try Argon2.hash(password: Array("pw".utf8), salt: salt, parameters: Argon2.Parameters(memoryKiB: 8, iterations: 1), outputLength: 100)
        #expect(out.count == 100)
        #expect(throws: Argon2.Error.self) {
            try Argon2.hash(password: [], salt: salt, parameters: Argon2.Parameters(memoryKiB: 4, iterations: 1), outputLength: 32)
        }
        #expect(throws: Argon2.Error.self) {
            try Argon2.hash(password: [], salt: [1, 2], parameters: Argon2.Parameters(memoryKiB: 8, iterations: 1), outputLength: 32)
        }
    }
}
