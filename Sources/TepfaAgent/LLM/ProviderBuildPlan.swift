import Foundation

/// One immutable capture of everything a provider build needs, taken before the vault prompt. The key,
/// the account and the configuration stay paired, so changing the Provider picker while Touch ID is up
/// cannot send one provider's key to another's host.
public struct ProviderBuildPlan: Sendable, Equatable {
    public let configuration: LLMProviderConfiguration
    /// The selected kind's key version when the plan was taken, so the panel records what it built.
    public let keyVersion: Int
    /// The account the snapshot's kind may read, or nil while a pending move withholds it.
    public let account: String?
    /// Whether `account` held a key when the plan was taken.
    public let hasKey: Bool

    public init(configuration: LLMProviderConfiguration, keyVersion: Int, account: String?, hasKey: Bool) {
        self.configuration = configuration
        self.keyVersion = keyVersion
        self.account = account
        self.hasKey = hasKey
    }
}

extension APIKeyMigration {
    /// Captures the configuration and the account that serves its kind right now. Do this before any
    /// await; build the provider and name the system prompt from the plan, never from live settings.
    public func plan(for configuration: LLMProviderConfiguration, keyVersion: Int) -> ProviderBuildPlan {
        ProviderBuildPlan(
            configuration: configuration,
            keyVersion: keyVersion,
            account: account(for: configuration.kind),
            hasKey: hasKey(for: configuration.kind)
        )
    }
}
