import Foundation
import Synchronization
import Testing
@testable import TepfaSSH

/// Opt-in end-to-end tests against a real sshd.
///
/// Set `TEPFA_TEST_SSH_PORT` and `TEPFA_TEST_SSH_KEY` (an unencrypted Ed25519
/// or ECDSA key listed in the server's authorized_keys). `TEPFA_TEST_SSH_HOST`
/// defaults to 127.0.0.1 and `TEPFA_TEST_SSH_USER` to the current user.
/// `Scripts/test-sshd.sh` starts a suitable throwaway server.
struct LiveServer: Sendable {
    let host: String
    let port: Int
    let user: String
    let keyPath: String

    static let current: LiveServer? = {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["TEPFA_TEST_SSH_PORT"], let port = Int(portText), let keyPath = env["TEPFA_TEST_SSH_KEY"] else {
            return nil
        }
        return LiveServer(
            host: env["TEPFA_TEST_SSH_HOST"] ?? "127.0.0.1",
            port: port,
            user: env["TEPFA_TEST_SSH_USER"] ?? NSUserName(),
            keyPath: keyPath)
    }()

    static var isConfigured: Bool { current != nil }
}

/// Gathers shell output from the event loop so tests can wait for it.
final class OutputCollector: Sendable {
    private let state = Mutex<(output: [UInt8], close: ShellCloseReason?)>(([], nil))

    func append(_ bytes: ArraySlice<UInt8>) {
        state.withLock { $0.output.append(contentsOf: bytes) }
    }

    func closed(_ reason: ShellCloseReason) {
        state.withLock { $0.close = reason }
    }

    var text: String {
        state.withLock { String(decoding: $0.output, as: UTF8.self) }
    }

    func waitForOutput(containing needle: String, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if text.contains(needle) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for \"\(needle)\"; output so far:\n\(text)")
    }

    func waitForClose(timeout: Duration = .seconds(10)) async throws -> ShellCloseReason? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let reason = state.withLock({ $0.close }) { return reason }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for the shell to close; output so far:\n\(text)")
        return nil
    }
}

@Suite(.enabled(if: LiveServer.isConfigured))
struct LiveServerTests {
    @Test func interactiveShellRoundTrip() async throws {
        let server = try #require(LiveServer.current)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let connection = try await SSHConnection.connect(
            host: server.host,
            port: server.port,
            credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
            hostKeyVerifier: InsecureAcceptAllHostKeys())
        #expect(connection.isActive)
        #expect(connection.hostKey?.fingerprintSHA256.hasPrefix("SHA256:") == true)

        let collector = OutputCollector()
        let shell = try await connection.openShell(
            cols: 100,
            rows: 30,
            onOutput: { collector.append($0) },
            onClose: { collector.closed($0) })

        // $COLUMNS proves the PTY request carried our size.
        shell.write("echo tepfa-$((40+2)) cols=$(tput cols)\n")
        try await collector.waitForOutput(containing: "tepfa-42 cols=100")

        shell.resize(cols: 132, rows: 40)
        shell.write("sleep 0.2; echo resized=$(tput cols)\n")
        try await collector.waitForOutput(containing: "resized=132")

        shell.write("exit 7\n")
        let reason = try await collector.waitForClose()
        #expect(reason?.exitStatus == 7)

        connection.close()
        await connection.waitUntilClosed()
        #expect(!connection.isActive)
    }

    @Test func unauthorizedKeyIsRejectedWithAReadableMessage() async throws {
        let server = try #require(LiveServer.current)
        let strangerKey = SSHPrivateKey(ed25519: .init(), comment: "not-authorized")
        do {
            let connection = try await SSHConnection.connect(
                host: server.host,
                port: server.port,
                credentials: SSHCredentials(username: server.user, secret: .privateKey(strangerKey)),
                hostKeyVerifier: InsecureAcceptAllHostKeys())
            connection.close()
            Issue.record("connection unexpectedly succeeded")
        } catch let error as SSHClientError {
            guard case .authenticationFailed(let detail) = error else {
                Issue.record("expected authenticationFailed, got \(error)")
                return
            }
            #expect(detail.contains("rejected"))
            #expect(detail.contains(strangerKey.fingerprintSHA256))
        }
    }

    @Test func declinedHostKeyAbortsTheConnection() async throws {
        let server = try #require(LiveServer.current)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let seen = Mutex<HostKeyInfo?>(nil)
        let verifier = ClosureHostKeyVerifier { info, _, _ in
            seen.withLock { $0 = info }
            return false
        }
        await #expect(throws: SSHClientError.hostKeyRejected) {
            _ = try await SSHConnection.connect(
                host: server.host,
                port: server.port,
                credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
                hostKeyVerifier: verifier)
        }
        #expect(seen.withLock { $0 }?.keyType == "ssh-ed25519")
    }

    @Test func closedPortFailsFast() async throws {
        do {
            _ = try await SSHConnection.connect(
                host: "127.0.0.1",
                port: 1,
                credentials: SSHCredentials(username: "nobody", secret: .password("x")),
                hostKeyVerifier: InsecureAcceptAllHostKeys(),
                connectTimeout: .seconds(5))
            Issue.record("connection unexpectedly succeeded")
        } catch let error as SSHClientError {
            guard case .connectionFailed = error else {
                Issue.record("expected connectionFailed, got \(error)")
                return
            }
        }
    }
}

@Suite(.enabled(if: LiveServer.isConfigured))
struct LiveExecTests {
    @Test func runsCommandsAndCollectsOutput() async throws {
        let server = try #require(LiveServer.current)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let connection = try await SSHConnection.connect(
            host: server.host, port: server.port,
            credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
            hostKeyVerifier: InsecureAcceptAllHostKeys())
        defer { connection.close() }

        let ok = try await connection.run("printf hello; printf err >&2; exit 0")
        #expect(ok.exitStatus == 0)
        #expect(ok.stdoutText == "hello")
        #expect(ok.stderrText == "err")

        let failing = try await connection.run("echo nope; exit 3")
        #expect(failing.exitStatus == 3)
        #expect(failing.stdoutText == "nope\n")

        let withStdin = try await connection.run("cat", stdin: Array("from stdin".utf8))
        #expect(withStdin.stdoutText == "from stdin")

        let env = try await connection.run("echo $TEPFA_X", environment: ["TEPFA_X": "set"])
        // sshd only passes env requests through when AcceptEnv allows them, so either answer is valid.
        #expect(env.exitStatus == 0)

        // The connection is still usable after several exec channels.
        let again = try await connection.run("echo again")
        #expect(again.stdoutText == "again\n")
    }

    @Test func commandTimeoutIsEnforced() async throws {
        let server = try #require(LiveServer.current)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let connection = try await SSHConnection.connect(
            host: server.host, port: server.port,
            credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
            hostKeyVerifier: InsecureAcceptAllHostKeys())
        defer { connection.close() }
        await #expect(throws: SSHClientError.self) {
            try await connection.run("sleep 30", timeout: .seconds(1))
        }
    }
}
