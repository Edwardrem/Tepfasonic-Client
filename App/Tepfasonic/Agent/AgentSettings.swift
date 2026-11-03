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
        didSet { save() }
    }
    private(set) var hasAPIKey: Bool

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configurationKey),
           let stored = try? JSONDecoder().decode(LLMProviderConfiguration.self, from: data) {
            configuration = stored
        } else {
            configuration = LLMProviderConfiguration()
        }
        hasAPIKey = SecretStore.shared.exists(account: SecretAccount.agentAPIKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.configurationKey)
        }
    }

    /// Reads the key, unlocking the vault (Touch ID) first when that is required.
    func apiKey() async throws -> String? {
        guard hasAPIKey else { return nil }
        try await Vault.shared.ensureUnlocked(reason: "use the saved API key for the Claude panel")
        return try SecretStore.shared.string(account: SecretAccount.agentAPIKey)
    }

    func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeAPIKey() }
        try SecretStore.shared.set(trimmed, account: SecretAccount.agentAPIKey, label: "Tepfasonic Claude API key")
        hasAPIKey = true
    }

    func removeAPIKey() throws {
        try SecretStore.shared.delete(account: SecretAccount.agentAPIKey)
        hasAPIKey = false
    }

    /// The configured provider; throws a readable message when something is missing.
    func makeProvider() async throws -> any LLMProvider {
        let key = try await apiKey()
        if configuration.kind == .anthropic, key == nil {
            throw AgentSetupError(message: "Add your Anthropic API key in Settings › Claude to start.")
        }
        return try configuration.makeProvider(apiKey: key)
    }
}

struct AgentSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
