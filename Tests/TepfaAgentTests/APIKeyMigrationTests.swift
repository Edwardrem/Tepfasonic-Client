import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("API key migration")
struct APIKeyMigrationTests {
    /// In-memory stand-in for the Keychain. A class so the migration's writes stay visible here.
    private final class FakeKeyStore: APIKeyStore, @unchecked Sendable {
        var items: [String: String] = [:]
        var labels: [String: String] = [:]
        /// Makes the next move fail, as a locked or busy Keychain would.
        var failNextMove = false
        /// Makes the next existence check fail, as a locked or busy Keychain would.
        var failNextExists = false
        /// Makes the next prefix check fail, as a locked or busy Keychain would.
        var failNextPrefix = false
        private(set) var moves = 0
        private(set) var deletions: [String] = []
        private(set) var prefixChecks = 0

        func itemExists(account: String) throws -> Bool {
            if failNextExists {
                failNextExists = false
                throw FakeError.existsFailed
            }
            return items[account] != nil
        }

        func itemHasPrefix(account: String, prefix: String) throws -> Bool {
            prefixChecks += 1
            if failNextPrefix {
                failNextPrefix = false
                throw FakeError.prefixFailed
            }
            return items[account]?.hasPrefix(prefix) ?? false
        }

        func move(from source: String, to destination: String, label: String) throws {
            moves += 1
            if failNextMove {
                failNextMove = false
                throw FakeError.moveFailed
            }
            guard let value = items[source] else { throw SecretStoreError.itemNotFound(source) }
            guard items[destination] == nil else { throw SecretStoreError.destinationNotEmpty(destination) }
            items[destination] = value
            items[source] = nil
            labels[destination] = label
        }

        func delete(account: String) throws {
            deletions.append(account)
            items[account] = nil
        }
    }

    private enum FakeError: Error {
        case moveFailed
        case existsFailed
        case prefixFailed
    }

    /// Every test gets its own defaults suite and removes it, so no decision leaks into the next run.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "tepfasonic-key-migration-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private var legacyAccount: String { LLMProviderConfiguration.Kind.anthropic.keychainAccount }
    private var endpointAccount: String { LLMProviderConfiguration.Kind.openAICompatible.keychainAccount }

    private func recordedState(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: APIKeyMigration.defaultsKey)
    }

    // MARK: Rule 1: one decision, from the old kind

    @Test func freshInstallRecordsItsDecision() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            APIKeyMigration(store: store, defaults: defaults).run(legacyKind: .anthropic)

            #expect(recordedState(defaults) == "settled")
            #expect(store.moves == 0)
            #expect(store.deletions.isEmpty)
            #expect(store.prefixChecks == 0, "a fresh install reads no item")
        }
    }

    @Test func theDecisionIsTakenOnceAndALaterKindChangeMovesNothing() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "anthropic-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .anthropic)
            // The user now picks a typed endpoint. The saved key is still the Anthropic one.
            migration.run(legacyKind: .openAICompatible)

            #expect(store.items[legacyAccount] == "anthropic-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(store.moves == 0)
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    // MARK: The first decision never guesses

    @Test func aFirstDecisionWithABusyEndpointAccountSettlesWithoutTouchingEitherItem() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            // 0.3.8 never wrote the endpoint account, so a filled one means this version already ran;
            // the item under agent.apiKey could be an Anthropic key and must not be deleted.
            store.items[legacyAccount] = "anthropic-test-key"
            store.items[endpointAccount] = "endpoint-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "settled")
            #expect(store.items[legacyAccount] == "anthropic-test-key")
            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(store.moves == 0)
            #expect(store.deletions.isEmpty)
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    @Test func aFirstDecisionThatCannotReadTheStoreStaysPendingAndTouchesNothing() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            store.items[endpointAccount] = "another-test-key"
            store.failNextExists = true
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "pendingMove")
            #expect(store.items[legacyAccount] == "endpoint-test-key")
            #expect(store.items[endpointAccount] == "another-test-key")
            #expect(store.moves == 0)
            #expect(store.deletions.isEmpty)
            #expect(migration.account(for: .anthropic) == nil)
        }
    }

    // MARK: Rule 2: Anthropic, or nothing saved, keeps the key

    @Test func oldAnthropicKeyStaysWithAnthropic() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "anthropic-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .anthropic)

            #expect(store.items[legacyAccount] == "anthropic-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(migration.account(for: .anthropic) == legacyAccount)
            #expect(store.moves == 0)
        }
    }

    @Test func noSavedConfigurationMeansAnthropicKeepsTheKey() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)

            // A fresh install has no stored kind, so task 3 passes Anthropic.
            migration.run(legacyKind: .anthropic)

            #expect(recordedState(defaults) == "settled")
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    // MARK: Rule 3: an endpoint key moves

    @Test func endpointKeyMovesToItsOwnAccount() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .openAICompatible)

            #expect(store.items[legacyAccount] == nil)
            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(store.labels[endpointAccount] == LLMProviderConfiguration.Kind.openAICompatible.keychainLabel)
            #expect(recordedState(defaults) == "settled")
            #expect(migration.account(for: .anthropic) == legacyAccount)
            #expect(migration.account(for: .openAICompatible) == endpointAccount)
        }
    }

    // MARK: Rule 4: a failed move stays pending and is retried

    @Test func failedMoveStaysPendingAndIsRetried() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            store.failNextMove = true
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "pendingMove")
            #expect(store.items[legacyAccount] == "endpoint-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(migration.account(for: .anthropic) == nil, "an endpoint key must never be offered to Anthropic")
            #expect(migration.account(for: .openAICompatible) == endpointAccount)

            // The next launch retries, whatever kind is selected by then.
            migration.run(legacyKind: .anthropic)

            #expect(store.items[legacyAccount] == nil)
            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(recordedState(defaults) == "settled")
            #expect(migration.account(for: .anthropic) == legacyAccount)
            #expect(store.moves == 2)
        }
    }

    @Test func aPendingMoveWithNothingLeftSettles() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            store.failNextMove = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(recordedState(defaults) == "pendingMove")

            // The user removed the key while the move was pending.
            store.items.removeAll()
            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "settled")
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    // MARK: An Anthropic key stays with Anthropic (rule 3, new)

    @Test func aFirstDecisionLeavesAnAnthropicKeyWhereItIs() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "sk-ant-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "settled")
            #expect(store.items[legacyAccount] == "sk-ant-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(store.moves == 0)
            #expect(store.deletions.isEmpty)
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    @Test func aPendingMoveLeavesAnAnthropicKeyWhereItIs() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            // An earlier launch could not read the store, so the move was left pending.
            store.items[legacyAccount] = "endpoint-test-key"
            store.failNextExists = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(recordedState(defaults) == "pendingMove")

            // The item turns out to be an Anthropic key: it must stay with Claude.
            store.items[legacyAccount] = "sk-ant-test-key"
            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "settled")
            #expect(store.items[legacyAccount] == "sk-ant-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(store.moves == 0)
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    @Test func aPendingMoveDoesNotDeleteAnAnthropicKeyWhenTheEndpointAccountIsFilled() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            store.failNextMove = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(recordedState(defaults) == "pendingMove")

            // The old item is an Anthropic key and the user has since saved an endpoint key.
            store.items[legacyAccount] = "sk-ant-test-key"
            store.items[endpointAccount] = "new-endpoint-test-key"
            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "settled")
            #expect(store.items[legacyAccount] == "sk-ant-test-key")
            #expect(store.items[endpointAccount] == "new-endpoint-test-key")
            #expect(store.deletions.isEmpty)
            #expect(migration.account(for: .anthropic) == legacyAccount)
        }
    }

    @Test func aFailingPrefixCheckStaysPendingAndTouchesNothing() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            store.failNextMove = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)
            #expect(recordedState(defaults) == "pendingMove")

            store.failNextPrefix = true
            migration.run(legacyKind: .openAICompatible)

            #expect(recordedState(defaults) == "pendingMove")
            #expect(store.items[legacyAccount] == "endpoint-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(store.moves == 1)
            #expect(store.deletions.isEmpty)
            #expect(migration.account(for: .anthropic) == nil)
        }
    }

    @Test func theAnthropicDecisionNeverReadsTheItem() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "anthropic-test-key"
            APIKeyMigration(store: store, defaults: defaults).run(legacyKind: .anthropic)

            #expect(store.prefixChecks == 0)
            #expect(store.items[legacyAccount] == "anthropic-test-key")
        }
    }

    // MARK: Rule 5: a new endpoint key supersedes the old one

    @Test func anEndpointKeySavedFirstSupersedesTheOldOne() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "old-endpoint-test-key"
            store.failNextMove = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            // An earlier launch left the move pending; only that recorded state allows the delete below.
            migration.run(legacyKind: .openAICompatible)
            #expect(recordedState(defaults) == "pendingMove")

            // The user typed a new endpoint key while the move was pending.
            store.items[endpointAccount] = "new-endpoint-test-key"

            migration.run(legacyKind: .openAICompatible)

            #expect(store.items[legacyAccount] == nil)
            #expect(store.items[endpointAccount] == "new-endpoint-test-key")
            #expect(store.deletions == [legacyAccount])
            #expect(recordedState(defaults) == "settled")
        }
    }

    // MARK: The one read returns only a Bool

    @Test func thePrefixCheckNeverReturnsOrStoresTheSecret() {
        // `itemHasPrefix` compares the value inside the store and answers only true/false, so the
        // migration can tell an Anthropic key from an endpoint key without holding either one.
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "sk-ant-test-key"
            APIKeyMigration(store: store, defaults: defaults).run(legacyKind: .openAICompatible)

            #expect(store.prefixChecks == 1)
            #expect(store.items[legacyAccount] == "sk-ant-test-key")
            #expect(store.items[endpointAccount] == nil)
            #expect(store.moves == 0)
        }
    }

    // MARK: The extras the brief asks for

    @Test func runningTheMigrationTwiceChangesNothingTheSecondTime() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[legacyAccount] = "endpoint-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)

            migration.run(legacyKind: .openAICompatible)
            #expect(store.moves == 1)

            migration.run(legacyKind: .openAICompatible)
            #expect(store.moves == 1)
            #expect(store.items[endpointAccount] == "endpoint-test-key")
            #expect(store.deletions.isEmpty)
        }
    }

    @Test func everyKindIsServedByItsOwnAccount() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            #expect(migration.account(for: .anthropic) == SecretAccount.agentAPIKey)
            #expect(migration.account(for: .openAICompatible) == SecretAccount.openAICompatibleAPIKey)
            #expect(migration.account(for: .caimex) == SecretAccount.caimexAPIKey)
            #expect(Set([SecretAccount.agentAPIKey, SecretAccount.openAICompatibleAPIKey, SecretAccount.caimexAPIKey]).count == 3)

            #expect(LLMProviderConfiguration.Kind.anthropic.keychainLabel == "Tepfasonic Claude API key")
            #expect(LLMProviderConfiguration.Kind.openAICompatible.keychainLabel == "Tepfasonic endpoint API key")
            #expect(LLMProviderConfiguration.Kind.caimex.keychainLabel == "Tepfasonic Caimex API key")
        }
    }
}
