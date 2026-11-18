import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("Provider build plan")
struct ProviderBuildPlanTests {
    private final class FakeKeyStore: APIKeyStore, @unchecked Sendable {
        var items: [String: String] = [:]
        var failMoves = false

        func itemExists(account: String) throws -> Bool { items[account] != nil }
        func itemHasPrefix(account: String, prefix: String) throws -> Bool { items[account]?.hasPrefix(prefix) ?? false }

        func move(from source: String, to destination: String, label: String) throws {
            if failMoves { throw FakeError.moveFailed }
            guard let value = items[source] else { throw SecretStoreError.itemNotFound(source) }
            guard items[destination] == nil else { throw SecretStoreError.destinationNotEmpty(destination) }
            items[destination] = value
            items[source] = nil
        }

        func delete(account: String) throws { items[account] = nil }
    }

    private enum FakeError: Error { case moveFailed }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "tepfasonic-provider-plan-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private var anthropicAccount: String { LLMProviderConfiguration.Kind.anthropic.keychainAccount }
    private var caimexAccount: String { LLMProviderConfiguration.Kind.caimex.keychainAccount }
    private var endpointAccount: String { LLMProviderConfiguration.Kind.openAICompatible.keychainAccount }

    @Test func aPlanCapturesTheKindAccountAndKeyState() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[caimexAccount] = "test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            var configuration = LLMProviderConfiguration(kind: .caimex)
            configuration.model = "deepseek-v4-flash"
            let plan = migration.plan(for: configuration, keyVersion: 7)

            #expect(plan.configuration.kind == .caimex)
            #expect(plan.configuration.model == "deepseek-v4-flash")
            #expect(plan.keyVersion == 7)
            #expect(plan.account == caimexAccount)
            #expect(plan.hasKey)
        }
    }

    @Test func aPlanIsNotRetargetedByALaterPickerChange() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            store.items[anthropicAccount] = "anthropic-test-key"
            store.items[caimexAccount] = "caimex-test-key"
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            var configuration = LLMProviderConfiguration(kind: .anthropic)
            let plan = migration.plan(for: configuration, keyVersion: 1)
            // The user changes the picker while the vault prompt is up.
            configuration.kind = .caimex

            #expect(plan.configuration.kind == .anthropic)
            #expect(plan.account == anthropicAccount)
            #expect(plan.keyVersion == 1)
            #expect(configuration.kind == .caimex, "the live settings may change; the plan does not")
        }
    }

    @Test func aPendingMovePlansAnthropicAsHavingNoKey() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            // An endpoint key under agent.apiKey with the move stuck pending: Anthropic must not use it.
            store.items[anthropicAccount] = "endpoint-test-key"
            store.failMoves = true
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .openAICompatible)

            let plan = migration.plan(for: LLMProviderConfiguration(kind: .anthropic), keyVersion: 0)

            #expect(plan.account == nil)
            #expect(!plan.hasKey)
        }
    }

    @Test func aKeylessEndpointPlansItsOwnAccountWithoutAKey() {
        withDefaults { defaults in
            let store = FakeKeyStore()
            let migration = APIKeyMigration(store: store, defaults: defaults)
            migration.run(legacyKind: .anthropic)

            let plan = migration.plan(for: LLMProviderConfiguration(kind: .openAICompatible), keyVersion: 3)

            #expect(plan.account == endpointAccount)
            #expect(!plan.hasKey)
        }
    }
}
