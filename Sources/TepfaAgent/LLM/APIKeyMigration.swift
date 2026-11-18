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
    /// What the endpoint key is called once it has its own account.
    static let endpointLabel = "Tepfasonic endpoint API key"

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
                record(.pendingMove)
                finishPendingMove()
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
                try store.move(from: source, to: destination, label: Self.endpointLabel)
            }
            record(.settled)
        } catch {
            // Stay pending: the next launch retries, and Anthropic keeps answering "no key" meanwhile.
        }
    }
}
