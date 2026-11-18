import Foundation
import Observation
import TepfaAgent
import TepfaCore

/// Provider choice, model and the API key for the Claude panel. The key lives
/// in the Keychain behind the vault; everything else is in UserDefaults.
@MainActor
@Observable
final class AgentSettings {
    static let shared = AgentSettings()
    static let configurationKey = "agent.provider"

    var configuration: LLMProviderConfiguration {
        didSet {
            save()
            // The key and its state belong to the selected kind.
            if configuration.kind != oldValue.kind {
                hasAPIKey = migration.hasKey(for: configuration.kind)
            }
        }
    }
    private(set) var hasAPIKey: Bool
    /// Bumped whenever the selected kind's saved key changes, so the panel rebuilds its provider even
    /// when the configuration (kind, model, URL) looks the same.
    private(set) var keyVersion = 0

    /// One migration for the app: run once in `init`, then consulted for every key operation.
    private let migration: APIKeyMigration
    /// The kind 0.3.8 had when this version first ran, so a pending move can be retried on save.
    private let legacyKind: LLMProviderConfiguration.Kind

    private init() {
        let stored: LLMProviderConfiguration
        if let data = UserDefaults.standard.data(forKey: Self.configurationKey),
           let decoded = try? JSONDecoder().decode(LLMProviderConfiguration.self, from: data) {
            stored = decoded
        } else {
            stored = LLMProviderConfiguration()
        }
        configuration = stored

        let migration = APIKeyMigration()
        // Decide who owns the 0.3.8 key before anything reads it.
        migration.run(legacyKind: stored.kind)
        self.migration = migration
        self.legacyKind = stored.kind
        hasAPIKey = migration.hasKey(for: stored.kind)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.configurationKey)
        }
    }

    /// Reads the selected kind's key, unlocking the vault (Touch ID) first when that is required.
    func apiKey() async throws -> String? {
        guard let account = migration.account(for: configuration.kind), hasAPIKey else { return nil }
        try await Vault.shared.ensureUnlocked(reason: "use the saved API key for the Claude panel")
        return try SecretStore.shared.string(account: account)
    }

    func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeAPIKey() }
        let kind = configuration.kind
        // A pending move withholds the account; retry it once, but never write to the old one.
        guard let account = migration.accountForSaving(kind, legacyKind: legacyKind) else {
            throw AgentSetupError(message: "Tepfasonic is still moving the key you saved before. Try again in a moment; nothing was saved.")
        }
        try SecretStore.shared.set(trimmed, account: account, label: kind.keychainLabel)
        hasAPIKey = true
        keyVersion += 1
    }

    func removeAPIKey() throws {
        guard let account = migration.account(for: configuration.kind) else { return }
        try SecretStore.shared.delete(account: account)
        hasAPIKey = false
        keyVersion += 1
    }

    /// The configured provider; throws a readable message when something is missing.
    func makeProvider() async throws -> any LLMProvider {
        let kind = configuration.kind
        let key = try await apiKey()
        if key == nil, kind.requiresAPIKey {
            throw AgentSetupError(message: "Add your \(kind.keyName) API key in Settings › Claude to start.")
        }
        return try configuration.makeProvider(apiKey: key)
    }
}

struct AgentSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
