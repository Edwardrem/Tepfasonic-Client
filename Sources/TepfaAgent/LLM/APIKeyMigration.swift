import Foundation
import TepfaCore

/// The Keychain operations the key migration needs. `itemHasPrefix` is the one operation that looks at
/// the secret: it compares the stored value with a fixed prefix and returns only a `Bool`, so the value
/// never leaves the store, is never stored, logged or returned, and the migration never asks the vault to
/// unlock.
public protocol APIKeyStore: Sendable {
    func itemExists(account: String) throws -> Bool
    /// Whether the item starts with `prefix` (false when there is no item). The value stays inside the
    /// store; only the comparison result leaves.
    func itemHasPrefix(account: String, prefix: String) throws -> Bool
    func move(from source: String, to destination: String, label: String) throws
    func delete(account: String) throws
}

extension SecretStore: APIKeyStore {}

/// Decides once who owns the API key 0.3.8 saved under `agent.apiKey`, then finishes any move that is
/// still pending. Because the decision is recorded, switching kind later cannot move that key again.
public struct APIKeyMigration {
    /// One place for the recorded decision: `settled` or `pendingMove`.
    public static let defaultsKey = "agent.keyMigration"
    /// Anthropic keys are recognisable by this prefix. The migration never moves or deletes one.
    public static let anthropicKeyPrefix = "sk-ant-"

    private enum State: String {
        case settled
        case pendingMove
    }

    private let store: any APIKeyStore
    private let defaults: UserDefaults

    public init(store: any APIKeyStore = SecretStore.shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// Runs the one-time decision from the kind 0.3.8 saved, and retries a move that is still pending.
    public func run(legacyKind: LLMProviderConfiguration.Kind) {
        switch recordedState {
        case .settled:
            return
        case .pendingMove:
            retryPendingMove()
        case nil:
            // Only a typed endpoint owned the old key; Anthropic (and a fresh install) keeps it.
            if legacyKind == .openAICompatible {
                beginMove()
            } else {
                record(.settled)
            }
        }
    }

    /// Retries a move an earlier launch left pending. Does nothing when the decision is settled or has not
    /// been taken, so the app can call it freely before a key operation.
    public func retryPendingMove() {
        guard recordedState == .pendingMove else { return }
        finishPendingMove()
    }

    /// The account this kind may use right now, or nil when its key must not be read. While a move is
    /// pending the old item is an endpoint key, so it is never offered to Anthropic.
    public func account(for kind: LLMProviderConfiguration.Kind) -> String? {
        if recordedState == .pendingMove, kind == .anthropic { return nil }
        return kind.keychainAccount
    }

    /// Whether the kind has a key it may use right now: false while its account is withheld, and false
    /// when the store cannot be read. Only that kind's own account is checked.
    public func hasKey(for kind: LLMProviderConfiguration.Kind) -> Bool {
        guard let account = account(for: kind) else { return false }
        return (try? store.itemExists(account: account)) ?? false
    }

    /// The account a key typed in Settings may be saved into. When a pending move withholds it, this
    /// retries the move once; nil still means "do not write", so the caller must refuse rather than fall
    /// back to the old account.
    public func accountForSaving(_ kind: LLMProviderConfiguration.Kind) -> String? {
        if let account = account(for: kind) { return account }
        retryPendingMove()
        return account(for: kind)
    }

    private var recordedState: State? {
        defaults.string(forKey: Self.defaultsKey).flatMap(State.init(rawValue:))
    }

    private func record(_ state: State) {
        defaults.set(state.rawValue, forKey: Self.defaultsKey)
    }

    /// The first decision. 0.3.8 never wrote the endpoint account, so an item already there means this
    /// version has run before: the old item is not provably an endpoint key, so settle without touching
    /// either one. Deleting is only for a move an earlier launch left pending.
    private func beginMove() {
        // `agent.apiKey` is the Anthropic account and the one 0.3.8 wrote every key to.
        let source = LLMProviderConfiguration.Kind.anthropic.keychainAccount
        let destination = LLMProviderConfiguration.Kind.openAICompatible.keychainAccount
        do {
            if try store.itemExists(account: destination) {
                record(.settled)
                return
            }
            // Record before the move so an interrupted first launch retries instead of forgetting it.
            record(.pendingMove)
            guard try store.itemExists(account: source) else {
                record(.settled)
                return
            }
            // An Anthropic key stays with Claude, even though the endpoint kind was selected.
            guard try !store.itemHasPrefix(account: source, prefix: Self.anthropicKeyPrefix) else {
                record(.settled)
                return
            }
            try store.move(
                from: source,
                to: destination,
                label: LLMProviderConfiguration.Kind.openAICompatible.keychainLabel
            )
            record(.settled)
        } catch {
            // Could not tell what is stored: keep the old item away from Anthropic until a later look.
            record(.pendingMove)
        }
    }

    private func finishPendingMove() {
        // `agent.apiKey` is the Anthropic account and the one 0.3.8 wrote every key to.
        let source = LLMProviderConfiguration.Kind.anthropic.keychainAccount
        let destination = LLMProviderConfiguration.Kind.openAICompatible.keychainAccount
        do {
            if try store.itemExists(account: destination) {
                // The user saved an endpoint key in the meantime, so an endpoint key may be superseded.
                if try store.itemExists(account: source) {
                    // But an Anthropic key must never be deleted as if it were an endpoint key.
                    if try !store.itemHasPrefix(account: source, prefix: Self.anthropicKeyPrefix) {
                        try store.delete(account: source)
                    }
                }
            } else if try store.itemExists(account: source) {
                // An Anthropic key stays with Claude; anything else belongs to the endpoint.
                if try !store.itemHasPrefix(account: source, prefix: Self.anthropicKeyPrefix) {
                    try store.move(
                        from: source,
                        to: destination,
                        label: LLMProviderConfiguration.Kind.openAICompatible.keychainLabel
                    )
                }
            }
            record(.settled)
        } catch {
            // Stay pending: the next launch retries, and Anthropic keeps answering "no key" meanwhile.
        }
    }
}
