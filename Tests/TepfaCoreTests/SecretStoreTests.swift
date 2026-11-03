import Foundation
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
}
