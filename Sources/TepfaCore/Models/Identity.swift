import Foundation
import SwiftData

/// A reusable login: a username plus a credential. The credential's secret
/// (password, key material or key passphrase) is never stored here; it lives in
/// the Keychain under `SecretStore` accounts derived from `uuid`.
@Model
public final class Identity {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    /// Login name. Empty means "use the host's username".
    public var username: String = ""
    /// Raw `CredentialKind`. Use `credentialKind`.
    public var credentialKindRaw: String = CredentialKind.keyFile.rawValue
    /// Path of the key file for `.keyFile`; empty otherwise.
    public var privateKeyPath: String
    /// OpenSSH public key line (`ssh-ed25519 AAAA… comment`), when known.
    public var publicKey: String?
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, … when known.
    public var keyType: String?
    /// `SHA256:…` fingerprint of the public key, when known.
    public var fingerprint: String?
    public var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \SSHHost.identity)
    public var hosts: [SSHHost]
    /// Groups that use this identity as their default.
    @Relationship(deleteRule: .nullify, inverse: \HostGroup.defaultIdentity)
    public var groupsByDefault: [HostGroup] = []

    public init(
        uuid: UUID = UUID(),
        name: String,
        username: String = "",
        credentialKind: CredentialKind = .keyFile,
        privateKeyPath: String = "",
        publicKey: String? = nil,
        keyType: String? = nil,
        fingerprint: String? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.username = username
        self.credentialKindRaw = credentialKind.rawValue
        self.privateKeyPath = privateKeyPath
        self.publicKey = publicKey
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.createdAt = .now
        self.hosts = []
    }

    public var credentialKind: CredentialKind {
        get { CredentialKind(rawValue: credentialKindRaw) ?? .keyFile }
        set { credentialKindRaw = newValue.rawValue }
    }

    public var hasKey: Bool { credentialKind != .password }

    /// Keychain accounts for this identity's secrets.
    public var passwordAccount: String { SecretAccount.identityPassword(uuid) }
    public var privateKeyAccount: String { SecretAccount.identityKey(uuid) }
    public var passphraseAccount: String { SecretAccount.identityPassphrase(uuid) }
}
