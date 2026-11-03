import Foundation
import TepfaCore
import TepfaSSH

/// What the user typed into a password or passphrase prompt.
public struct SecretAnswer: Sendable, Equatable {
    public var secret: String
    public var remember: Bool

    public init(secret: String, remember: Bool = false) {
        self.secret = secret
        self.remember = remember
    }
}

/// Turns a `HostDescriptor` into `SSHCredentials`: saved secrets first, the
/// user second. UI-agnostic; the session and the key-push sheet supply prompts.
@MainActor
public struct CredentialResolver {
    public struct Resolution: Sendable {
        public var credentials: SSHCredentials
        /// True when the password came from the store, so a rejection should delete it.
        public var passwordFromStore: Bool
    }

    public enum Failure: Error, LocalizedError {
        case noIdentity
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noIdentity: "This host uses an identity but none is assigned. Edit the host to choose one."
            case .cancelled: "Cancelled."
            }
        }
    }

    public var store: any CredentialStore
    public var askPassword: @MainActor (HostDescriptor) async -> SecretAnswer?
    public var askPassphrase: @MainActor (IdentityDescriptor, _ attemptFailed: Bool) async -> SecretAnswer?
    public var notify: @MainActor (String) -> Void

    public init(
        store: any CredentialStore,
        askPassword: @escaping @MainActor (HostDescriptor) async -> SecretAnswer?,
        askPassphrase: @escaping @MainActor (IdentityDescriptor, _ attemptFailed: Bool) async -> SecretAnswer?,
        notify: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.store = store
        self.askPassword = askPassword
        self.askPassphrase = askPassphrase
        self.notify = notify
    }

    /// Throws `Failure.cancelled` when the user dismisses a prompt or the vault.
    public func resolve(for host: HostDescriptor) async throws -> Resolution {
        let username = host.loginUsername
        if let identity = host.identity {
            switch identity.kind {
            case .password:
                return try await password(for: host, username: username)
            case .keyFile, .keychainKey:
                return try await key(identity: identity, host: host, username: username)
            }
        }
        switch host.authMethod {
        case .password:
            return try await password(for: host, username: username)
        case .privateKey:
            throw Failure.noIdentity
        }
    }

    private func password(for host: HostDescriptor, username: String) async throws -> Resolution {
        do {
            if let stored = try await store.storedPassword(for: host) {
                return Resolution(credentials: SSHCredentials(username: username, secret: .password(stored)), passwordFromStore: true)
            }
        } catch VaultError.cancelled {
            throw Failure.cancelled
        } catch {
            notify("Could not read the saved password: \(error.localizedDescription)")
        }
        guard let answer = await askPassword(host) else { throw Failure.cancelled }
        if answer.remember, !host.isTransient {
            do {
                try store.remember(password: answer.secret, for: host)
            } catch {
                notify("Could not save the password: \(error.localizedDescription)")
            }
        }
        return Resolution(credentials: SSHCredentials(username: username, secret: .password(answer.secret)), passwordFromStore: false)
    }

    private func key(identity: IdentityDescriptor, host: HostDescriptor, username: String) async throws -> Resolution {
        var passphrase: String?
        var passphraseFromStore = false
        do {
            passphrase = try await store.storedPassphrase(for: identity)
            passphraseFromStore = passphrase != nil
        } catch VaultError.cancelled {
            throw Failure.cancelled
        } catch {
            notify("Could not read the saved passphrase: \(error.localizedDescription)")
        }

        var attemptFailed = false
        while true {
            do {
                let key = try await store.privateKey(for: identity, passphrase: passphrase)
                return Resolution(credentials: SSHCredentials(username: username, secret: .privateKey(key)), passwordFromStore: false)
            } catch SSHKeyError.passphraseRequired, SSHKeyError.wrongPassphrase {
                if passphraseFromStore {
                    store.forgetPassphrase(for: identity)
                    passphraseFromStore = false
                    notify("The saved passphrase for \(identity.name) was rejected and has been removed.")
                    attemptFailed = true
                } else if passphrase != nil {
                    attemptFailed = true
                }
                guard let answer = await askPassphrase(identity, attemptFailed) else { throw Failure.cancelled }
                passphrase = answer.secret
                if answer.remember {
                    do {
                        try store.remember(passphrase: answer.secret, for: identity)
                        passphraseFromStore = true
                    } catch {
                        notify("Could not save the passphrase: \(error.localizedDescription)")
                    }
                }
            } catch VaultError.cancelled {
                throw Failure.cancelled
            }
        }
    }
}
