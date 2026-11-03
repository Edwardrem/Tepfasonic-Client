import Foundation
import TepfaCore
import TepfaSSH

/// Where saved passwords, passphrases and Keychain-resident keys come from.
/// Implementations may throw `VaultError.cancelled` when the user declines to unlock.
@MainActor
public protocol CredentialStore: AnyObject {
    /// The saved password for the host (its identity's, or the host's own). Nil when none is saved.
    func storedPassword(for host: HostDescriptor) async throws -> String?
    func remember(password: String, for host: HostDescriptor) throws
    func forgetPassword(for host: HostDescriptor)

    /// Loads the identity's key. Throws `SSHKeyError.passphraseRequired` or
    /// `.wrongPassphrase` when the file needs a different passphrase.
    func privateKey(for identity: IdentityDescriptor, passphrase: String?) async throws -> SSHPrivateKey
    func storedPassphrase(for identity: IdentityDescriptor) async throws -> String?
    func remember(passphrase: String, for identity: IdentityDescriptor) throws
    func forgetPassphrase(for identity: IdentityDescriptor)
}

/// The production store: secrets in the Keychain behind the `Vault`.
@MainActor
public final class KeychainCredentialStore: CredentialStore {
    public static let shared = KeychainCredentialStore()

    public let secrets: SecretStore
    public let vault: Vault

    public init(secrets: SecretStore = .shared, vault: Vault = .shared) {
        self.secrets = secrets
        self.vault = vault
    }

    public static func passwordAccount(for host: HostDescriptor) -> String {
        if let identity = host.identity, identity.kind == .password {
            return SecretAccount.identityPassword(identity.id)
        }
        return SecretAccount.hostPassword(host.id)
    }

    public func hasStoredPassword(for host: HostDescriptor) -> Bool {
        secrets.exists(account: Self.passwordAccount(for: host))
    }

    public func storedPassword(for host: HostDescriptor) async throws -> String? {
        let account = Self.passwordAccount(for: host)
        guard secrets.exists(account: account) else { return nil }
        try await vault.ensureUnlocked(reason: "use the saved password for \(host.target)")
        return try secrets.string(account: account)
    }

    public func remember(password: String, for host: HostDescriptor) throws {
        try secrets.set(password, account: Self.passwordAccount(for: host), label: "Tepfasonic password: \(host.target)")
    }

    public func forgetPassword(for host: HostDescriptor) {
        try? secrets.delete(account: Self.passwordAccount(for: host))
    }

    public func privateKey(for identity: IdentityDescriptor, passphrase: String?) async throws -> SSHPrivateKey {
        switch identity.kind {
        case .keyFile:
            return try SSHPrivateKey.load(fromPath: identity.privateKeyPath, passphrase: passphrase)
        case .keychainKey:
            let account = SecretAccount.identityKey(identity.id)
            guard secrets.exists(account: account) else {
                throw SSHKeyError.unreadableFile("the Keychain item for \(identity.name)")
            }
            try await vault.ensureUnlocked(reason: "use the key \(identity.name)")
            guard let text = try secrets.string(account: account) else {
                throw SSHKeyError.unreadableFile("the Keychain item for \(identity.name)")
            }
            return try SSHPrivateKey.parse(text, passphrase: passphrase)
        case .password:
            throw SSHKeyError.invalidFormat("\(identity.name) is a password identity, not a key")
        }
    }

    public func hasStoredPassphrase(for identity: IdentityDescriptor) -> Bool {
        secrets.exists(account: SecretAccount.identityPassphrase(identity.id))
    }

    public func storedPassphrase(for identity: IdentityDescriptor) async throws -> String? {
        let account = SecretAccount.identityPassphrase(identity.id)
        guard secrets.exists(account: account) else { return nil }
        try await vault.ensureUnlocked(reason: "use the saved passphrase for \(identity.name)")
        return try secrets.string(account: account)
    }

    public func remember(passphrase: String, for identity: IdentityDescriptor) throws {
        try secrets.set(passphrase, account: SecretAccount.identityPassphrase(identity.id), label: "Tepfasonic passphrase: \(identity.name)")
    }

    public func forgetPassphrase(for identity: IdentityDescriptor) {
        try? secrets.delete(account: SecretAccount.identityPassphrase(identity.id))
    }

    // MARK: Key material management (Identities window)

    /// Stores a private key in the Keychain, unencrypted inside the item.
    public func store(keyPair: SSHKeyPair, for identityID: UUID, name: String) throws {
        try secrets.set(try keyPair.openSSHPrivateKey(), account: SecretAccount.identityKey(identityID), label: "Tepfasonic key: \(name)")
    }

    /// Reads a key for export or pushing. Prompts to unlock when it lives in the Keychain.
    public func keyPair(for identity: IdentityDescriptor, passphrase: String? = nil) async throws -> SSHKeyPair {
        switch identity.kind {
        case .keychainKey:
            try await vault.ensureUnlocked(reason: "export the key \(identity.name)")
            guard let text = try secrets.string(account: SecretAccount.identityKey(identity.id)) else {
                throw SSHKeyError.unreadableFile("the Keychain item for \(identity.name)")
            }
            return try SSHKeyPair.parse(text)
        case .keyFile:
            var stored = passphrase
            if stored == nil { stored = try await storedPassphrase(for: identity) }
            return try SSHKeyPair.load(from: URL(fileURLWithPath: (identity.privateKeyPath as NSString).expandingTildeInPath), passphrase: stored)
        case .password:
            throw SSHKeyError.invalidFormat("\(identity.name) is a password identity, not a key")
        }
    }

    public func storePassword(_ password: String, forIdentity identityID: UUID, name: String) throws {
        try secrets.set(password, account: SecretAccount.identityPassword(identityID), label: "Tepfasonic password: \(name)")
    }

    public func hasStoredPassword(forIdentity identityID: UUID) -> Bool {
        secrets.exists(account: SecretAccount.identityPassword(identityID))
    }

    /// Removes every secret that belonged to the identity.
    public func deleteSecrets(forIdentity identityID: UUID) {
        for account in SecretAccount.all(forIdentity: identityID) {
            try? secrets.delete(account: account)
        }
    }
}
