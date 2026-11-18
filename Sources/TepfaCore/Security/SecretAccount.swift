import Foundation

/// Keychain account names used by `SecretStore`, in one place so the model,
/// the credential store and the settings UI agree.
public enum SecretAccount {
    public static func identityPassword(_ id: UUID) -> String { "identity.\(id.uuidString).password" }
    public static func identityKey(_ id: UUID) -> String { "identity.\(id.uuidString).key" }
    public static func identityPassphrase(_ id: UUID) -> String { "identity.\(id.uuidString).passphrase" }
    public static func hostPassword(_ id: UUID) -> String { "host.\(id.uuidString).password" }
    /// The Anthropic API key for the Claude agent panel. 0.3.8 saved every kind's key here.
    public static let agentAPIKey = "agent.apiKey"
    /// The API key for a user-typed OpenAI-compatible endpoint, kept apart so an Anthropic key never
    /// travels to it.
    public static let openAICompatibleAPIKey = "agent.openAICompatible.apiKey"
    /// The API key for the Caimex provider, kept apart so it can sit beside an Anthropic key.
    public static let caimexAPIKey = "agent.caimex.apiKey"
    /// Password for the proxy configured on a host or group (`ownerID` is the host's or group's UUID).
    public static func proxyPassword(_ ownerID: UUID) -> String { "proxy.\(ownerID.uuidString).password" }
    /// Cloud provider credentials, keyed by provider id (`aws`, `digitalocean`, `azure`).
    public static func cloudCredential(_ provider: String) -> String { "cloud.\(provider).credential" }

    /// Every account that can belong to the identity.
    public static func all(forIdentity id: UUID) -> [String] {
        [identityPassword(id), identityKey(id), identityPassphrase(id)]
    }
}
