import Foundation
import TepfaCore
import TepfaSSH

/// Moves secrets between the Keychain and a `.tepfa` document.
@MainActor
enum ExportSecrets {
    /// Reads an identity's secret for an encrypted export. A key file whose
    /// passphrase is saved is exported decrypted so it works without the file.
    static func read(_ identity: Identity) throws -> TepfaDocument.IdentitySecrets? {
        let store = SecretStore.shared
        var out = TepfaDocument.IdentitySecrets()
        switch identity.credentialKind {
        case .password:
            out.password = try store.string(account: identity.passwordAccount)
        case .keychainKey:
            out.privateKey = try store.string(account: identity.privateKeyAccount)
        case .keyFile:
            let path = (identity.privateKeyPath as NSString).expandingTildeInPath
            let passphrase = try store.string(account: identity.passphraseAccount)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                if let passphrase, let pair = try? SSHKeyPair.parse(text, passphrase: passphrase), let plain = try? pair.openSSHPrivateKey() {
                    out.privateKey = plain
                } else {
                    out.privateKey = text
                    out.passphrase = passphrase
                }
            } else {
                out.passphrase = passphrase
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Stores imported secrets for an identity that now exists.
    static func write(_ secrets: TepfaDocument.IdentitySecrets, for identity: Identity) throws {
        let store = SecretStore.shared
        if let password = secrets.password {
            try store.set(password, account: identity.passwordAccount, label: "Tepfasonic password: \(identity.name)")
        }
        if let key = secrets.privateKey {
            try store.set(key, account: identity.privateKeyAccount, label: "Tepfasonic key: \(identity.name)")
            if identity.fingerprint == nil, let pair = try? SSHKeyPair.parse(key) {
                IdentityOperations.apply(pair, to: identity)
            }
        }
        if let passphrase = secrets.passphrase {
            try store.set(passphrase, account: identity.passphraseAccount, label: "Tepfasonic passphrase: \(identity.name)")
        }
    }
}
