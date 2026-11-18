import Foundation
import Security
import Testing
@testable import TepfaCore

/// Opt-in because it writes to the login keychain: `TEPFA_KEYCHAIN_TESTS=1 swift test --filter SecretStore`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEPFA_KEYCHAIN_TESTS"] == "1"))
struct SecretStoreTests {
    @Test func roundTripsUpdatesAndDeletes() throws {
        let store = SecretStore(service: "com.tepfasonic.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        #expect(try store.string(account: "a") == nil)
        #expect(!store.exists(account: "a"))

        try store.set("first", account: "a")
        #expect(store.exists(account: "a"))
        #expect(try store.string(account: "a") == "first")

        try store.set("second", account: "a")
        #expect(try store.string(account: "a") == "second")

        try store.set(Data([0, 1, 2]), account: "b")
        #expect(try store.accounts() == ["a", "b"])

        try store.delete(account: "a")
        try store.delete(account: "a") // idempotent
        #expect(try store.string(account: "a") == nil)
        #expect(try store.accounts() == ["b"])

        try store.deleteAll()
        #expect(try store.accounts().isEmpty)
    }

    // MARK: Moving an item to another account

    @Test func moveChangesTheAccountAndTheLabelWithoutReadingTheSecret() throws {
        let store = SecretStore(service: "com.tepfasonic.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        try store.set("first", account: "a", label: "old label")
        try store.move(from: "a", to: "b", label: "new label")

        #expect(try store.string(account: "a") == nil)
        #expect(try store.string(account: "b") == "first")
        #expect(try store.accounts() == ["b"])
        #expect(try label(of: "b", in: store) == "new label")
    }

    @Test func moveRefusesToOverwriteAndChangesNothing() throws {
        let store = SecretStore(service: "com.tepfasonic.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        try store.set("source-secret", account: "a", label: "source label")
        try store.set("destination-secret", account: "b", label: "destination label")

        #expect(throws: SecretStoreError.destinationNotEmpty("b")) {
            try store.move(from: "a", to: "b", label: "new label")
        }
        #expect(try store.string(account: "a") == "source-secret")
        #expect(try store.string(account: "b") == "destination-secret")
        #expect(try label(of: "b", in: store) == "destination label")
    }

    @Test func moveReportsAMissingSource() throws {
        let store = SecretStore(service: "com.tepfasonic.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        #expect(throws: SecretStoreError.itemNotFound("missing")) {
            try store.move(from: "missing", to: "b", label: "new label")
        }
        #expect(try store.accounts().isEmpty)
    }

    private func label(of account: String, in store: SecretStore) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        return (result as? [String: Any])?[kSecAttrLabel as String] as? String
    }
}
