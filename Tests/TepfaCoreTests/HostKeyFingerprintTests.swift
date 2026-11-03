import Foundation
import Testing
@testable import TepfaCore

// Vectors generated with the system ssh-keygen (`ssh-keygen -lf`).
@Suite struct HostKeyFingerprintTests {
    @Test func ed25519MatchesSSHKeygen() {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECxNoPNaw3QpARDuRo9wbsAsKfVlQduK40/MqLlOuB+ tepfa-test-ed25519"
        #expect(HostKeyFingerprint.sha256(openSSHPublicKey: line) == "SHA256:7vwtpeRqyDuurDQlkywB2udH6UcuoaxJDtOfzrqqpFU")
    }

    @Test func ecdsaMatchesSSHKeygen() {
        let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEQnj6gDHwcybk6+REEF6uqWbSfoxXvIzmj8cUB3OJfRkABxktynPKuRmmELtAC49kq6GFL1Or2da83CYSvaAG0="
        #expect(HostKeyFingerprint.sha256(openSSHPublicKey: line) == "SHA256:kwVNs9qyAQqdDkT49aBBmgN9XdM7D2Mq5IfX8IFyk5I")
    }

    @Test func rsaMatchesSSHKeygen() {
        let line = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDDR9VsI2R+oOUBQ6afQQ/98RM3ja1y8xV3wWKMTCCLrCcebXClVXI0YsCA+DPNYPal00uUs2Q727FSRWJy5WiIEfBxbSyyPGDY7Y8oeV/buwTQSTaBSEwttegtvasLN3qBexSJxt6mtV7+QGmjka4MRiwYidGNPi+3w8L0tWpSUnXot2iNjjpMmnvX5kBCbvE3modUO+azoE0GiHINP8tM4eGGv16O3SQaaizRz+V/aTdWU2N519XvZI+9I+cDbKzjkDBxNrfYQK/Tg7AP+Nx2iBfyMjRF7TJG5LFJK8f5TTj0Y/bzqR7JIdQTo0lmwVAmPRIHyvZ/C4FpUPVv9qtT"
        #expect(HostKeyFingerprint.sha256(openSSHPublicKey: line) == "SHA256:2T/HesmpthRB6ym0uXu/+t1L0JvE4wfxtAwFqU7BkyY")
    }

    @Test func malformedLinesReturnNil() {
        #expect(HostKeyFingerprint.sha256(openSSHPublicKey: "ssh-ed25519") == nil)
        #expect(HostKeyFingerprint.sha256(openSSHPublicKey: "ssh-ed25519 not-base64!!") == nil)
        #expect(HostKeyFingerprint.normalize(openSSHPublicKey: "ssh-ed25519 AAAA comment here") == "ssh-ed25519 AAAA")
    }
}
