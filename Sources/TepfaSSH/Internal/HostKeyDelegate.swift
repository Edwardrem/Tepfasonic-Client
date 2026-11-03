import NIOCore
import NIOSSH
import Synchronization

/// Bridges NIOSSH's host-key callback to an async `HostKeyVerifier`.
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let verifier: any HostKeyVerifier
    private let presented = Mutex<HostKeyInfo?>(nil)

    init(host: String, port: Int, verifier: any HostKeyVerifier) {
        self.host = host
        self.port = port
        self.verifier = verifier
    }

    /// The key the server presented, once the handshake reached that point.
    var presentedKey: HostKeyInfo? {
        presented.withLock { $0 }
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(hostKey)
        presented.withLock { $0 = info }
        let verifier = self.verifier
        let host = self.host
        let port = self.port
        Task {
            if await verifier.verify(hostKey: info, host: host, port: port) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHClientError.hostKeyRejected)
            }
        }
    }
}
