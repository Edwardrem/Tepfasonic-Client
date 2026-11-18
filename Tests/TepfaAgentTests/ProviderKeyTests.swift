import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("Provider key state")
struct ProviderKeyTests {
    /// In-memory stand-in for the Keychain. A class so the migration's writes stay visible here.
    private final class FakeKeyStore: APIKeyStore, @unchecked Sendable {
        var items: [String: String] = [:]
        var labels: [String: String] = [:]
        /// A locked or busy Keychain: every move fails until the test clears it.
        var failMoves = false
        /// Every existence check fails, as a locked Keychain would.
        var failExists = false
        private(set) var moves = 0

        func itemExists(account: String) throws -> Bool {
            if failExists { throw FakeError.existsFailed }
            return items[account] != nil
        }

        func itemHasPrefix(account: String, prefix: String) throws -> Bool {
            items[account]?.hasPrefix(prefix) ?? false
        }

        func move(from source: String, to destination: String, label: String) throws {
            moves += 1
            if failMoves { throw FakeError.moveFailed }
            guard let value = items[source] else { throw SecretStoreError.itemNotFound(source) }
            guard items[destination] == nil else { throw SecretStoreError.destinationNotEmpty(destination) }
            items[destination] = value
            items[source] = nil
            labels[destination] = label
        }

        func delete(account: String) throws { items[account] = nil }
    }

    private enum FakeError: Error {
        case moveFailed
        case existsFailed
    }

    /// Every test gets its own defaults suite and removes it, so no decision leaks into the next run.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "tepfasonic-provider-key-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private var anthropicAccount: String { LLMProviderConfiguration.Kind.anthropic.keychainAccount }
    private var caimexAccount: String { LLMProviderConfiguration.Kind.caimex.keychainAccount }
    private var endpointAccount: String { LLMProviderConfiguration.Kind.openAICompatible.keychainAccount }

    // MARK: hasKey: the per-kind state the settings screen shows

    @Test func hasKeyIsTrueOnlyForTheKindWhoseOwnAccountHoldsAnItem() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[caimexAccount] = "test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            #expect(migration.hasKey(for: .caimex))
            #expect(!migration.hasKey(for: .anthropic))
            #expect(!migration.hasKey(for: .openAICompatible))
        }
    }

    @Test func hasKeyIsFalseWhileAPendingMoveWithholdsAnthropic() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            // 0.3.8 saved an endpoint key under agent.apiKey and the move failed.
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            #expect(migration.account(for: .anthropic) == nil)
            #expect(!migration.hasKey(for: .anthropic), "an endpoint key must never count as Anthropic's")
        }
    }

    @Test func hasKeyIsFalseWhenTheStoreCannotBeRead() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)
            store.failExists = true

            #expect(!migration.hasKey(for: .anthropic))
        }
    }

    @Test func hasKeyIsFalseWithNoItem() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            #expect(!migration.hasKey(for: .anthropic))
            #expect(!migration.hasKey(for: .caimex))
            #expect(!migration.hasKey(for: .openAICompatible))
        }
    }

    // MARK: accountForSaving: retry once, never fall back

    @Test func accountForSavingAnswersTheKindsOwnAccountWhenNoMoveIsPending() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            #expect(migration.accountForSaving(.anthropic) == anthropicAccount)
            #expect(migration.accountForSaving(.caimex) == caimexAccount)
            #expect(migration.accountForSaving(.openAICompatible) == endpointAccount)
            #expect(store.moves == 0)
        }
    }

    @Test func accountForSavingRetriesAPendingMoveOnceThenAnswersTheAccount() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(migration.account(for: .anthropic) == nil)

            // The Keychain works again: saving retries the move, then may use Anthropic's account.
            store.failMoves = false
            #expect(migration.accountForSaving(.anthropic) == anthropicAccount)
            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(store.items[anthropicAccount] == nil)
            #expect(store.labels[endpointAccount] == LLMProviderConfiguration.Kind.openAICompatible.keychainLabel)
        }
    }

    @Test func accountForSavingRefusesWhileTheMoveStillFails() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            // Saving must write nothing rather than fall back to agent.apiKey.
            #expect(migration.accountForSaving(.anthropic) == nil)
            #expect(store.items[anthropicAccount] == "endpoint-test-key")
            #expect(store.items[endpointAccount] == nil)
        }
    }

    @Test func accountForSavingDoesNotRetakeASettledDecision() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "anthropic-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            // A recorded decision is never retaken, so a save cannot move the Anthropic key.
            #expect(migration.accountForSaving(.anthropic) == anthropicAccount)
            #expect(store.items[anthropicAccount] == "anthropic-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(store.moves == 0)
        }
    }

    // MARK: retryPendingMove

    @Test func retryPendingMoveCompletesAnEndpointMove() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(!migration.hasKey(for: .openAICompatible), "the endpoint has no key while the move is pending")

            // A later attempt from the app, while the endpoint kind is selected, finishes the move.
            store.failMoves = false
            migration.retryPendingMove()

            #expect(migration.hasKey(for: .openAICompatible))
            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(store.items[anthropicAccount] == nil)
        }
    }

    @Test func retryPendingMoveDoesNothingWhenSettled() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "anthropic-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            migration.retryPendingMove()

            #expect(store.moves == 0)
            #expect(store.items[anthropicAccount] == "anthropic-test-key")
        }
    }

    @Test func retryPendingMoveStaysPendingWhenTheMoveFails() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            migration.retryPendingMove()

            #expect(migration.account(for: .anthropic) == nil)
            #expect(!migration.hasKey(for: .openAICompatible))
            #expect(store.items[anthropicAccount] == "endpoint-test-key")
            #expect(store.items[endpointAccount] == nil)
        }
    }

    // MARK: Kind rules the settings screen and setup error read

    @Test func apiKeyRequirementAndNameFollowTheKind() {
        #expect(LLMProviderConfiguration.Kind.anthropic.requiresAPIKey)
        #expect(LLMProviderConfiguration.Kind.caimex.requiresAPIKey)
        #expect(!LLMProviderConfiguration.Kind.openAICompatible.requiresAPIKey)
        #expect(LLMProviderConfiguration.Kind.anthropic.keyName == "Anthropic")
        #expect(LLMProviderConfiguration.Kind.caimex.keyName == "Caimex")
        #expect(LLMProviderConfiguration.Kind.openAICompatible.keyName == "endpoint")
    }
}
