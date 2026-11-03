import Foundation

/// What an `Identity` authenticates with.
public enum CredentialKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A password stored in the Keychain.
    case password
    /// A private key file on disk (optionally with its passphrase in the Keychain).
    case keyFile
    /// A private key whose material lives only in the Keychain.
    case keychainKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .password: "Password"
        case .keyFile: "Key file"
        case .keychainKey: "Key in Keychain"
        }
    }

    public var systemImage: String {
        switch self {
        case .password: "key.horizontal"
        case .keyFile: "doc.badge.ellipsis"
        case .keychainKey: "key.fill"
        }
    }
}
