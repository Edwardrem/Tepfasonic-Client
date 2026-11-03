import Foundation
import Testing
@testable import TepfaCore

@Suite struct TepfaFileTests {
    private let fastKDF = Argon2.Parameters(variant: .id, memoryKiB: 64, iterations: 1, parallelism: 1)

    private func sampleDocument() -> TepfaDocument {
        var document = TepfaDocument(exportedAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "0.1")
        let group = UUID()
        let identity = UUID()
        document.groups = [.init(id: group, name: "Lab", sortOrder: 0, colorLabel: "#5E9CFF")]
        document.identities = [.init(id: identity, name: "deploy", username: "deploy", credentialKind: "keychainKey", keyType: "ssh-ed25519", fingerprint: "SHA256:abc")]
        document.hosts = [.init(id: UUID(), name: "box", hostname: "10.0.0.5", username: "ubuntu", authMethod: "privateKey", tags: ["ci"], groupID: group, identityID: identity)]
        document.snippets = [.init(id: UUID(), name: "disk", command: "df -h")]
        document.knownHosts = [.init(host: "10.0.0.5", port: 22, keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAA", fingerprintSHA256: "SHA256:xyz")]
        return document
    }

    @Test func plainRoundTripIsReadableJSON() throws {
        let document = sampleDocument()
        let data = try TepfaFile.encode(document, passphrase: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? String == "tepfa")
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(!TepfaFile.isEncrypted(data))
        #expect(TepfaFile.isTepfa(data))
        #expect(try TepfaFile.decode(data, passphrase: nil) == document)
    }

    @Test func encryptedRoundTripNeedsTheRightPassphrase() throws {
        var document = sampleDocument()
        document.secrets = TepfaDocument.SecretsRecord(identities: [document.identities[0].id.uuidString: .init(privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n")])
        let data = try TepfaFile.encode(document, passphrase: "correct horse", kdf: fastKDF)
        #expect(TepfaFile.isEncrypted(data))
        #expect(TepfaFile.isTepfa(data))
        #expect(!String(decoding: data, as: UTF8.self).contains("10.0.0.5"))
        #expect(try TepfaFile.decode(data, passphrase: "correct horse") == document)
        #expect(throws: TepfaFile.Error.passphraseRequired) { try TepfaFile.decode(data, passphrase: nil) }
        #expect(throws: TepfaFile.Error.wrongPassphrase) { try TepfaFile.decode(data, passphrase: "wrong") }
    }

    @Test func tamperedCiphertextIsRejected() throws {
        let data = try TepfaFile.encode(sampleDocument(), passphrase: "pw", kdf: fastKDF)
        var envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ciphertext = try #require(Data(base64Encoded: envelope["ciphertext"] as! String))
        ciphertext[5] ^= 0x01
        envelope["ciphertext"] = ciphertext.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: TepfaFile.Error.wrongPassphrase) { try TepfaFile.decode(tampered, passphrase: "pw") }
    }

    @Test func plainExportRefusesSecretsAndUnknownFilesAreRejected() throws {
        var document = sampleDocument()
        document.secrets = TepfaDocument.SecretsRecord(identities: ["x": .init(password: "p")])
        #expect(throws: TepfaFile.Error.plainExportCannotIncludeSecrets) { try TepfaFile.encode(document, passphrase: nil) }
        #expect(throws: TepfaFile.Error.notATepfaFile) { try TepfaFile.decode(Data("{\"hello\":1}".utf8), passphrase: nil) }
        #expect(throws: TepfaFile.Error.notATepfaFile) { try TepfaFile.decode(Data("not json".utf8), passphrase: nil) }
        #expect(throws: TepfaFile.Error.unsupportedSchema(2)) {
            try TepfaFile.decode(Data("{\"format\":\"tepfa\",\"schemaVersion\":2,\"exportedAt\":\"2026-11-03T10:00:00Z\"}".utf8), passphrase: nil)
        }
    }

    @Test func olderDocumentsWithMissingArraysDecode() throws {
        let minimal = Data("{\"format\":\"tepfa\",\"schemaVersion\":1,\"exportedAt\":\"2026-11-03T10:00:00Z\",\"hosts\":[]}".utf8)
        let document = try TepfaFile.decode(minimal, passphrase: nil)
        #expect(document.isEmpty)
    }
}
