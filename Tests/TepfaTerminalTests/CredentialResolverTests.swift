import Foundation
import Testing
import TepfaCore
import TepfaSSH
@testable import TepfaTerminal

/// An in-memory credential store with a controllable vault.
@MainActor
final class FakeCredentialStore: CredentialStore {
    var passwords: [String: String] = [:]
    var passphrases: [UUID: String] = [:]
    var keys: [UUID: String] = [:]
    var vaultCancelled = false
    private(set) var forgottenPasswords = 0
    private(set) var forgottenPassphrases = 0

    func storedPassword(for host: HostDescriptor) async throws -> String? {
        let account = KeychainCredentialStore.passwordAccount(for: host)
        guard let password = passwords[account] else { return nil }
        if vaultCancelled { throw VaultError.cancelled }
        return password
    }

    func remember(password: String, for host: HostDescriptor) throws {
        passwords[KeychainCredentialStore.passwordAccount(for: host)] = password
    }

    func forgetPassword(for host: HostDescriptor) {
        forgottenPasswords += 1
        passwords[KeychainCredentialStore.passwordAccount(for: host)] = nil
    }

    func privateKey(for identity: IdentityDescriptor, passphrase: String?) async throws -> SSHPrivateKey {
        switch identity.kind {
        case .keyFile: return try SSHPrivateKey.load(fromPath: identity.privateKeyPath, passphrase: passphrase)
        case .keychainKey:
            guard let text = keys[identity.id] else { throw SSHKeyError.unreadableFile("keychain") }
            if vaultCancelled { throw VaultError.cancelled }
            return try SSHPrivateKey.parse(text, passphrase: passphrase)
        case .password: throw SSHKeyError.invalidFormat("not a key")
        }
    }

    func storedPassphrase(for identity: IdentityDescriptor) async throws -> String? {
        guard let passphrase = passphrases[identity.id] else { return nil }
        if vaultCancelled { throw VaultError.cancelled }
        return passphrase
    }

    func remember(passphrase: String, for identity: IdentityDescriptor) throws {
        passphrases[identity.id] = passphrase
    }

    func forgetPassphrase(for identity: IdentityDescriptor) {
        forgottenPassphrases += 1
        passphrases[identity.id] = nil
    }
}

@Suite @MainActor struct CredentialResolverTests {
    private static let encryptedKeyPath: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tepfa-resolver-\(UUID().uuidString).key")
        let pair = try! SSHKeyPair.generate(.ed25519, comment: "resolver")
        try! pair.openSSHPrivateKey(passphrase: "open sesame", rounds: 1).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }()

    private func resolver(
        store: FakeCredentialStore,
        password: @escaping @MainActor () -> SecretAnswer? = { nil },
        passphrase: @escaping @MainActor (Bool) -> SecretAnswer? = { _ in nil }
    ) -> CredentialResolver {
        CredentialResolver(store: store, askPassword: { _ in password() }, askPassphrase: { _, failed in passphrase(failed) })
    }

    @Test func usesTheStoredPasswordWithoutPrompting() async throws {
        let store = FakeCredentialStore()
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice")
        try store.remember(password: "pw", for: host)
        let resolution = try await resolver(store: store, password: { Issue.record("must not prompt"); return nil }).resolve(for: host)
        #expect(resolution.passwordFromStore)
        #expect(resolution.credentials.username == "alice")
        guard case .password("pw") = resolution.credentials.secret else { Issue.record("expected password"); return }
    }

    @Test func promptsAndRemembersOnRequest() async throws {
        let store = FakeCredentialStore()
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice")
        let resolution = try await resolver(store: store, password: { SecretAnswer(secret: "typed", remember: true) }).resolve(for: host)
        #expect(!resolution.passwordFromStore)
        #expect(try await store.storedPassword(for: host) == "typed")
    }

    @Test func transientHostsAreNeverRemembered() async throws {
        let store = FakeCredentialStore()
        let host = HostDescriptor.quickConnect("alice@example.org")!
        _ = try await resolver(store: store, password: { SecretAnswer(secret: "typed", remember: true) }).resolve(for: host)
        #expect(store.passwords.isEmpty)
    }

    @Test func identityUsernameOverridesTheHost() async throws {
        let store = FakeCredentialStore()
        let identity = IdentityDescriptor(name: "deploy", username: "deploy", kind: .password)
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice", authMethod: .privateKey, identity: identity)
        let resolution = try await resolver(store: store, password: { SecretAnswer(secret: "x") }).resolve(for: host)
        #expect(resolution.credentials.username == "deploy")
        #expect(host.target == "deploy@h")
    }

    @Test func cancellingThePromptOrVaultIsReportedAsCancelled() async throws {
        let store = FakeCredentialStore()
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice")
        await #expect(throws: CredentialResolver.Failure.self) {
            try await resolver(store: store).resolve(for: host)
        }
        try store.remember(password: "pw", for: host)
        store.vaultCancelled = true
        await #expect(throws: CredentialResolver.Failure.self) {
            try await resolver(store: store, password: { Issue.record("must not prompt after a cancelled unlock"); return nil }).resolve(for: host)
        }
    }

    @Test func keyIdentityWithoutIdentityFails() async {
        let store = FakeCredentialStore()
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice", authMethod: .privateKey)
        await #expect(throws: CredentialResolver.Failure.self) { try await resolver(store: store).resolve(for: host) }
    }

    @Test func encryptedKeyFileAsksForThePassphraseUntilItIsRight() async throws {
        let store = FakeCredentialStore()
        let identity = IdentityDescriptor(name: "enc", kind: .keyFile, privateKeyPath: Self.encryptedKeyPath)
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice", authMethod: .privateKey, identity: identity)
        var attempts: [Bool] = []
        let answers = ["wrong", "open sesame"]
        let resolution = try await resolver(store: store, passphrase: { failed in
            attempts.append(failed)
            return SecretAnswer(secret: answers[attempts.count - 1], remember: attempts.count == 2)
        }).resolve(for: host)
        #expect(attempts == [false, true])
        guard case .privateKey(let key) = resolution.credentials.secret else { Issue.record("expected a key"); return }
        #expect(key.keyType == .ed25519)
        #expect(store.passphrases[identity.id] == "open sesame")
    }

    @Test func rejectedStoredPassphraseIsForgottenThenAsked() async throws {
        let store = FakeCredentialStore()
        let identity = IdentityDescriptor(name: "enc", kind: .keyFile, privateKeyPath: Self.encryptedKeyPath)
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice", authMethod: .privateKey, identity: identity)
        try store.remember(passphrase: "stale", for: identity)
        var sawFailure = false
        _ = try await resolver(store: store, passphrase: { failed in
            sawFailure = failed
            return SecretAnswer(secret: "open sesame")
        }).resolve(for: host)
        #expect(sawFailure)
        #expect(store.forgottenPassphrases == 1)
        #expect(store.passphrases[identity.id] == nil)
    }

    @Test func keychainKeysLoadWithoutAPassphrase() async throws {
        let store = FakeCredentialStore()
        let pair = try SSHKeyPair.generate(.ecdsaP256)
        let identity = IdentityDescriptor(name: "kc", kind: .keychainKey)
        store.keys[identity.id] = try pair.openSSHPrivateKey()
        let host = HostDescriptor(name: "h", hostname: "h", username: "alice", authMethod: .privateKey, identity: identity)
        let resolution = try await resolver(store: store, passphrase: { _ in Issue.record("must not prompt"); return nil }).resolve(for: host)
        guard case .privateKey(let key) = resolution.credentials.secret else { Issue.record("expected a key"); return }
        #expect(key.fingerprintSHA256 == pair.fingerprintSHA256)
    }

    @Test func keyPusherScriptQuotesTheKeyAndPath() {
        let script = KeyPusher.script(for: "ssh-ed25519 AAAA it's a comment", authorizedKeysPath: "~/.ssh/authorized_keys")
        #expect(script.contains("'ssh-ed25519 AAAA its a comment'"))
        #expect(script.contains("~/'.ssh/authorized_keys'"))
        #expect(script.contains("TEPFA_ADDED"))
        let absolute = KeyPusher.script(for: "ssh-ed25519 AAAA", authorizedKeysPath: "/tmp/x/keys")
        #expect(absolute.contains("mkdir -p '/tmp/x'"))
    }
}
