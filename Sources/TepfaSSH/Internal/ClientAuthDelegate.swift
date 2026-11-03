import NIOCore
import NIOSSH

/// Offers exactly one credential. A second request means the server rejected
/// it, so we fail the handshake with a readable message instead of looping.
final class ClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let credentials: SSHCredentials
    /// Only touched on the connection's event loop.
    private var attempts = 0

    init(credentials: SSHCredentials) {
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        attempts += 1
        guard attempts == 1 else {
            nextChallengePromise.fail(SSHClientError.authenticationFailed(rejectionMessage(availableMethods)))
            return
        }

        switch credentials.secret {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(SSHClientError.authenticationFailed(
                    "the server does not accept password authentication (it offers \(describe(availableMethods)))"))
                return
            }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "",
                offer: .password(.init(password: password))))

        case .privateKey(let key):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHClientError.authenticationFailed(
                    "the server does not accept public-key authentication (it offers \(describe(availableMethods)))"))
                return
            }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: key.nioKey))))
        }
    }

    private func rejectionMessage(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> String {
        switch credentials.secret {
        case .password:
            "the server rejected the password for \(credentials.username)"
        case .privateKey(let key):
            "the server rejected the \(key.keyType.rawValue) key (\(key.fingerprintSHA256)) for \(credentials.username)"
        }
    }

    private func describe(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> String {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names.isEmpty ? "no methods" : names.joined(separator: ", ")
    }
}
