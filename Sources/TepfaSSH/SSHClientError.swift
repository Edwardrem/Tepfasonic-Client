import Foundation

/// Errors surfaced by `SSHConnection` and `SSHShellSession`.
public enum SSHClientError: Error, LocalizedError, Sendable, Equatable {
    /// TCP connect, DNS or SSH handshake failure.
    case connectionFailed(String)
    /// The server closed the connection before we finished authenticating.
    case connectionClosed
    /// The host-key verifier declined the server's key.
    case hostKeyRejected
    case authenticationFailed(String)
    case channelFailed(String)
    /// The task running the command was cancelled; the channel was closed.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): "Could not connect: \(detail)"
        case .connectionClosed: "The server closed the connection."
        case .hostKeyRejected: "The server's host key was not trusted."
        case .authenticationFailed(let detail): "Authentication failed: \(detail)"
        case .channelFailed(let detail): "Could not open a session: \(detail)"
        case .cancelled: "The command was cancelled."
        }
    }
}

/// Errors from loading or parsing private keys.
public enum SSHKeyError: Error, LocalizedError, Sendable, Equatable {
    case unreadableFile(String)
    case invalidFormat(String)
    /// The key is encrypted and no passphrase was given.
    case passphraseRequired
    case wrongPassphrase
    case unsupportedFormat(String)
    case unsupportedKeyType(String)
    /// The key was parsed but cannot be used to authenticate (RSA with SwiftNIO SSH).
    case cannotAuthenticate(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            "Could not read the private key at \(path)."
        case .invalidFormat(let detail):
            "The private key could not be parsed: \(detail)."
        case .passphraseRequired:
            "This private key is protected by a passphrase."
        case .wrongPassphrase:
            "The passphrase is incorrect."
        case .unsupportedFormat(let what):
            "Tepfasonic cannot read \(what) yet."
        case .unsupportedKeyType(let type):
            "\(type) keys are not supported. Tepfasonic supports Ed25519, ECDSA (P-256/384/521) and RSA keys."
        case .cannotAuthenticate(let type):
            "\(type) keys can be stored, exported and pushed to servers, but SwiftNIO SSH cannot sign with them, so they cannot be used to connect. Use an Ed25519 or ECDSA key for connections."
        }
    }
}
