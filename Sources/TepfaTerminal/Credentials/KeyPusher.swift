import Foundation
import Synchronization
import TepfaCore
import TepfaSSH

/// `ssh-copy-id` without the script: appends a public key to the remote
/// `~/.ssh/authorized_keys` over an exec channel.
public enum KeyPusher {
    public enum Outcome: Sendable, Equatable {
        case added
        case alreadyPresent
    }

    public enum PushError: Error, LocalizedError {
        /// The server's key is not in the known hosts list; call again with `trustHostKey: true` to accept it.
        case unknownHostKey(HostKeyInfo, changed: Bool)
        case remoteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unknownHostKey(let key, let changed):
                changed
                    ? "The host key has CHANGED to \(key.fingerprintSHA256). Only continue if you expected this."
                    : "The server presented an unknown \(key.keyType) key: \(key.fingerprintSHA256)."
            case .remoteFailed(let output):
                "The server could not add the key: \(output)"
            }
        }
    }

    public static let defaultAuthorizedKeysPath = "~/.ssh/authorized_keys"

    /// The POSIX shell snippet run on the server. Public so the agent and tests can show it.
    public static func script(for publicKey: String, authorizedKeysPath: String = defaultAuthorizedKeysPath) -> String {
        let line = publicKey.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let file = authorizedKeysPath.replacingOccurrences(of: "'", with: "")
        let directory = (file as NSString).deletingLastPathComponent
        // The path is left unquoted around ~ so the remote shell expands it; everything else is quoted.
        func quoted(_ path: String) -> String {
            path.hasPrefix("~/") ? "~/'\(path.dropFirst(2))'" : "'\(path)'"
        }
        return "umask 077; mkdir -p \(quoted(directory)) && touch \(quoted(file)) && chmod 700 \(quoted(directory)) && chmod 600 \(quoted(file)) && "
            + "if grep -qF -- '\(line)' \(quoted(file)); then echo TEPFA_PRESENT; else printf '%s\\n' '\(line)' >> \(quoted(file)) && echo TEPFA_ADDED; fi"
    }

    public static func push(
        publicKey: String,
        to host: HostDescriptor,
        credentials: SSHCredentials,
        knownHosts: KnownHostsStore = .shared,
        trustHostKey: Bool = false,
        authorizedKeysPath: String = defaultAuthorizedKeysPath
    ) async throws -> Outcome {
        let rejected = Mutex<(HostKeyInfo, Bool)?>(nil)
        let verifier = ClosureHostKeyVerifier { key, hostname, port in
            let verdict = await knownHosts.verdict(host: hostname, port: port, keyType: key.keyType, publicKey: key.openSSHPublicKey)
            switch verdict {
            case .known:
                return true
            case .unknown, .changed:
                guard trustHostKey else {
                    rejected.withLock { $0 = (key, verdict != .unknown) }
                    return false
                }
                if case .changed = verdict {
                    try? await knownHosts.forget(host: hostname, port: port, keyType: key.keyType)
                }
                _ = try? await knownHosts.remember(
                    host: hostname, port: port, keyType: key.keyType,
                    publicKey: key.openSSHPublicKey, fingerprintSHA256: key.fingerprintSHA256)
                return true
            }
        }

        let connection: SSHConnection
        do {
            connection = try await SSHConnection.connect(host: host.hostname, port: host.port, credentials: credentials, hostKeyVerifier: verifier)
        } catch {
            if let (key, changed) = rejected.withLock({ $0 }) {
                throw PushError.unknownHostKey(key, changed: changed)
            }
            throw error
        }
        defer { connection.close() }

        let result = try await connection.run(script(for: publicKey, authorizedKeysPath: authorizedKeysPath))
        let output = (result.stdoutText + result.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.stdoutText.contains("TEPFA_ADDED") { return .added }
        if result.stdoutText.contains("TEPFA_PRESENT") { return .alreadyPresent }
        throw PushError.remoteFailed(output.isEmpty ? "exit status \(result.exitStatus.map(String.init) ?? "unknown")" : output)
    }
}
