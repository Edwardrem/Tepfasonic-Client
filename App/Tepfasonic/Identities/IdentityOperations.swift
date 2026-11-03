import AppKit
import Foundation
import SwiftData
import TepfaCore
import TepfaSSH
import TepfaTerminal
import UniformTypeIdentifiers

/// Shared identity/key actions used by the editor, the Identities window and the sheets.
@MainActor
enum IdentityOperations {
    static let store = KeychainCredentialStore.shared

    /// Creates (or reuses) a file-backed identity for a key on disk. Encrypted
    /// keys are accepted; the passphrase is asked for when connecting.
    static func identityForKeyFile(at url: URL, existing: [Identity], in context: ModelContext) throws -> Identity {
        var pair: SSHKeyPair?
        do {
            pair = try SSHKeyPair.load(from: url)
        } catch SSHKeyError.passphraseRequired {
            pair = nil
        }
        if let found = existing.first(where: { $0.credentialKind == .keyFile && $0.privateKeyPath == url.path }) {
            if let pair { apply(pair, to: found) }
            return found
        }
        let suffix = pair?.comment.map { " (\($0))" } ?? ""
        let identity = Identity(name: url.lastPathComponent + suffix, credentialKind: .keyFile, privateKeyPath: url.path)
        if let pair { apply(pair, to: identity) }
        context.insert(identity)
        try context.save()
        return identity
    }

    static func apply(_ pair: SSHKeyPair, to identity: Identity) {
        identity.publicKey = pair.openSSHPublicKey
        identity.keyType = pair.keyType
        identity.fingerprint = pair.fingerprintSHA256
    }

    /// Stores a key pair in the Keychain and creates the identity for it.
    static func createKeychainIdentity(name: String, username: String, pair: SSHKeyPair, in context: ModelContext) throws -> Identity {
        let identity = Identity(name: name, username: username, credentialKind: .keychainKey)
        apply(pair, to: identity)
        try store.store(keyPair: pair, for: identity.uuid, name: name)
        context.insert(identity)
        try context.save()
        return identity
    }

    /// Writes the key pair to disk (private 0600, public alongside) and creates a file identity.
    static func createFileIdentity(
        name: String, username: String, pair: SSHKeyPair, at url: URL,
        passphrase: String?, rememberPassphrase: Bool, in context: ModelContext
    ) throws -> Identity {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = try pair.openSSHPrivateKey(passphrase: passphrase)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try (pair.openSSHPublicKey + "\n").write(to: url.appendingPathExtension("pub"), atomically: true, encoding: .utf8)

        let identity = Identity(name: name, username: username, credentialKind: .keyFile, privateKeyPath: url.path)
        apply(pair, to: identity)
        if let passphrase, rememberPassphrase {
            try store.remember(passphrase: passphrase, for: IdentityDescriptor(identity))
        }
        context.insert(identity)
        try context.save()
        return identity
    }

    static func createPasswordIdentity(name: String, username: String, password: String, in context: ModelContext) throws -> Identity {
        let identity = Identity(name: name, username: username, credentialKind: .password)
        try store.storePassword(password, forIdentity: identity.uuid, name: name)
        context.insert(identity)
        try context.save()
        return identity
    }

    /// Deletes the identity and every secret that belonged to it. Hosts keep working but lose the identity.
    static func delete(_ identity: Identity, in context: ModelContext) {
        store.deleteSecrets(forIdentity: identity.uuid)
        for host in identity.hosts {
            host.identity = nil
        }
        context.delete(identity)
        try? context.save()
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func savePublicKey(_ publicKey: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Export Public Key"
        panel.nameFieldStringValue = suggestedName.hasSuffix(".pub") ? suggestedName : suggestedName + ".pub"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (publicKey + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the private key in OpenSSH format with 0600 permissions.
    static func savePrivateKey(_ pair: SSHKeyPair, passphrase: String?, suggestedName: String) throws {
        let panel = NSSavePanel()
        panel.title = "Export Private Key"
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try pair.openSSHPrivateKey(passphrase: passphrase).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func chooseKeyFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import a private key"
        panel.message = "OpenSSH, PEM (PKCS#1, PKCS#8, SEC1) and PuTTY .ppk files are supported."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static var defaultComment: String {
        "\(NSUserName())@\(Host.current().localizedName ?? "mac")"
    }
}
