import Foundation
import Testing
@testable import TepfaCore

@Suite @MainActor struct VaultTests {
    private func makeVault(require: Bool = true) -> Vault {
        let defaults = UserDefaults(suiteName: "tepfa-vault-tests-\(UUID().uuidString)")!
        defaults.set(require, forKey: Vault.requireAuthenticationKey)
        return Vault(defaults: defaults)
    }

    @Test func startsLockedAndUnlocksThroughTheAuthenticator() async throws {
        let vault = makeVault()
        var prompts = 0
        vault.authenticator = { _ in prompts += 1 }
        #expect(vault.isLocked)
        try await vault.ensureUnlocked(reason: "test")
        #expect(!vault.isLocked)
        try await vault.ensureUnlocked(reason: "again")
        #expect(prompts == 1, "an unlocked vault must not prompt again")
        vault.lock()
        #expect(vault.isLocked)
    }

    @Test func cancellationLeavesItLocked() async {
        let vault = makeVault()
        vault.authenticator = { _ in throw VaultError.cancelled }
        await #expect(throws: VaultError.cancelled) {
            try await vault.ensureUnlocked(reason: "test")
        }
        #expect(vault.isLocked)
        #expect(vault.lastError == nil)
    }

    @Test func failuresAreRecorded() async {
        let vault = makeVault()
        vault.authenticator = { _ in throw VaultError.unavailable("no biometrics") }
        await #expect(throws: VaultError.self) { try await vault.ensureUnlocked(reason: "test") }
        #expect(vault.lastError?.contains("no biometrics") == true)
    }

    @Test func concurrentRequestsShareOnePrompt() async throws {
        let vault = makeVault()
        var prompts = 0
        vault.authenticator = { _ in
            prompts += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        async let first: Void = vault.ensureUnlocked(reason: "a")
        async let second: Void = vault.ensureUnlocked(reason: "b")
        _ = try await (first, second)
        #expect(prompts == 1)
        #expect(!vault.isLocked)
    }

    @Test func disabledRequirementIsAlwaysUnlocked() async throws {
        let vault = makeVault(require: false)
        vault.authenticator = { _ in Issue.record("must not prompt") }
        #expect(!vault.isLocked)
        try await vault.ensureUnlocked(reason: "test")
        vault.lock()
        #expect(!vault.isLocked)
    }
}
