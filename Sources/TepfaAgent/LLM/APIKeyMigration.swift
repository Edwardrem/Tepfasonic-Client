import Foundation
import TepfaCore

/// The Keychain operations the key migration needs. There is no read, so the migration can move or
/// delete an item but can never see, copy or log the secret, and it never asks the vault to unlock.
public protocol APIKeyStore: Sendable {
    func itemExists(account: String) throws -> Bool
    func move(from source: String, to destination: String, label: String) throws
    func delete(account: String) throws
}

extension SecretStore: APIKeyStore {}

/// Decides once who owns the API key 0.3.8 saved under `agent.apiKey`, then finishes any move that is
/// still pending. Because the decision is recorded, switching kind later cannot move that key again.
public struct APIKeyMigration {
    /// One place for the recorded decision: `settled` or `pendingMove`.
    public static let defaultsKey = "agent.keyMigration"

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
            finishPendingMove()
        case nil:
            // Only a typed endpoint owned the old key; Anthropic (and a fresh install) keeps it.
            if legacyKind == .openAICompatible {
                beginMove()
            } else {
                record(.settled)
            }
        }
    }

    /// The account this kind may use right now, or nil when its key must not be read. While a move is
    /// pending the old item is an endpoint key, so it is never offered to Anthropic.
    public func account(for kind: LLMProviderConfiguration.Kind) -> String? {
        if recordedState == .pendingMove, kind == .anthropic { return nil }
        return kind.keychainAccount
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
                // The user saved an endpoint key in the meantime, so the old one is superseded.
                if try store.itemExists(account: source) {
                    try store.delete(account: source)
                }
            } else if try store.itemExists(account: source) {
                try store.move(
                    from: source,
                    to: destination,
                    label: LLMProviderConfiguration.Kind.openAICompatible.keychainLabel
                )
            }
            record(.settled)
        } catch {
            // Stay pending: the next launch retries, and Anthropic keeps answering "no key" meanwhile.
        }
    }
}
