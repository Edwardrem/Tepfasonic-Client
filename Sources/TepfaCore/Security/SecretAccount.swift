import Foundation

/// Keychain account names used by `SecretStore`, in one place so the model,
/// the credential store and the settings UI agree.
public enum SecretAccount {
    public static func identityPassword(_ id: UUID) -> String { "identity.\(id.uuidString).password" }
    public static func identityKey(_ id: UUID) -> String { "identity.\(id.uuidString).key" }
    public static func identityPassphrase(_ id: UUID) -> String { "identity.\(id.uuidString).passphrase" }
    public static func hostPassword(_ id: UUID) -> String { "host.\(id.uuidString).password" }
    /// The API key for the Claude agent panel (Anthropic or an OpenAI-compatible endpoint).
    public static let agentAPIKey = "agent.apiKey"

    /// Every account that can belong to the identity.
    public static func all(forIdentity id: UUID) -> [String] {
        [identityPassword(id), identityKey(id), identityPassphrase(id)]
    }
}
