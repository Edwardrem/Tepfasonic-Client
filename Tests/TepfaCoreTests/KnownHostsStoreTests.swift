import Foundation
import Testing
@testable import TepfaCore

@Suite struct KnownHostsStoreTests {
    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECxNoPNaw3QpARDuRo9wbsAsKfVlQduK40/MqLlOuB+"
    private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8Gg26l3HPSsL8M4f4kg0Y4hC9V6V28rCJQoHZdUeU0"

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "tepfa-tests-\(UUID().uuidString)")
            .appending(path: "known_hosts.json")
    }

    @Test func unknownThenKnownThenChanged() async throws {
        let store = KnownHostsStore(url: temporaryURL())
        #expect(await store.verdict(host: "example.com", port: 22, keyType: "ssh-ed25519", publicKey: keyA) == .unknown)

        try await store.remember(host: "example.com", port: 22, keyType: "ssh-ed25519", publicKey: keyA + " some comment", fingerprintSHA256: "SHA256:x")

        // Host names compare case-insensitively and comments are ignored.
        #expect(await store.verdict(host: "EXAMPLE.com", port: 22, keyType: "ssh-ed25519", publicKey: keyA + " other comment") == .known)

        // A different port is a different server.
        #expect(await store.verdict(host: "example.com", port: 2222, keyType: "ssh-ed25519", publicKey: keyA) == .unknown)

        // A different key type is not a mismatch, just unknown.
        #expect(await store.verdict(host: "example.com", port: 22, keyType: "ecdsa-sha2-nistp256", publicKey: "ecdsa-sha2-nistp256 AAAA") == .unknown)

        if case .changed(let previous) = await store.verdict(host: "example.com", port: 22, keyType: "ssh-ed25519", publicKey: keyB) {
            #expect(previous.publicKey == keyA)
        } else {
            Issue.record("expected .changed")
        }
    }

    @Test func persistsAcrossInstancesAndForgets() async throws {
        let url = temporaryURL()
        let first = KnownHostsStore(url: url)
        try await first.remember(host: "box", port: 22, keyType: "ssh-ed25519", publicKey: keyA, fingerprintSHA256: "SHA256:x")
        try await first.remember(host: "box", port: 22, keyType: "ecdsa-sha2-nistp256", publicKey: "ecdsa-sha2-nistp256 AAAA", fingerprintSHA256: "SHA256:y")

        let second = KnownHostsStore(url: url)
        #expect(await second.allEntries().count == 2)
        #expect(await second.verdict(host: "box", port: 22, keyType: "ssh-ed25519", publicKey: keyA) == .known)

        try await second.forget(host: "box", port: 22)
        #expect(await second.allEntries().isEmpty)

        let third = KnownHostsStore(url: url)
        #expect(await third.verdict(host: "box", port: 22, keyType: "ssh-ed25519", publicKey: keyA) == .unknown)
    }

    @Test func missingFileIsEmpty() async {
        let store = KnownHostsStore(url: temporaryURL())
        #expect(await store.allEntries().isEmpty)
    }
}
