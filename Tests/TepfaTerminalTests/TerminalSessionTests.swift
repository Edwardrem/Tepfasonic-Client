import Foundation
import Testing
import TepfaCore
import TepfaSSH
@testable import TepfaTerminal

/// Collects everything the session would feed to the terminal view.
@MainActor
final class CollectingSink: TerminalSink {
    private(set) var bytes: [UInt8] = []
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func feed(_ bytes: ArraySlice<UInt8>) { self.bytes.append(contentsOf: bytes) }
}

@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("timed out waiting for \(what)")
}

private func temporaryKnownHosts() -> KnownHostsStore {
    KnownHostsStore(url: FileManager.default.temporaryDirectory
        .appending(path: "tepfa-terminal-tests-\(UUID().uuidString)")
        .appending(path: "known_hosts.json"))
}

@Suite @MainActor struct TerminalSessionOfflineTests {
    @Test func cancellingThePasswordPromptReturnsToIdle() async throws {
        let session = TerminalSession(
            host: HostDescriptor(name: "box", hostname: "127.0.0.1", port: 1, username: "u", authMethod: .password),
            knownHosts: temporaryKnownHosts())
        let connecting = Task { await session.connect() }
        try await waitUntil("password prompt") { session.prompt != nil }
        guard case .password(let respond) = session.prompt else {
            Issue.record("expected a password prompt, got \(String(describing: session.prompt))")
            return
        }
        #expect(session.state == .connecting)
        respond.resume(returning: nil)
        await connecting.value
        #expect(session.state == .idle)
        #expect(session.prompt == nil)
    }

    @Test func keyHostWithoutIdentityFails() async {
        let session = TerminalSession(
            host: HostDescriptor(name: "box", hostname: "127.0.0.1", port: 1, username: "u", authMethod: .privateKey),
            knownHosts: temporaryKnownHosts())
        await session.connect()
        guard case .failed(let message) = session.state else {
            Issue.record("expected .failed, got \(session.state)")
            return
        }
        #expect(message.contains("none is assigned"))
    }

    @Test func unreadableKeyFails() async {
        let session = TerminalSession(
            host: HostDescriptor(name: "box", hostname: "127.0.0.1", port: 1, username: "u", authMethod: .privateKey, identity: IdentityDescriptor(name: "missing", kind: .keyFile, privateKeyPath: "/nonexistent/key")),
            knownHosts: temporaryKnownHosts())
        await session.connect()
        guard case .failed(let message) = session.state else {
            Issue.record("expected .failed, got \(session.state)")
            return
        }
        #expect(message.contains("/nonexistent/key"))
    }

    @Test func disconnectingAnIdleSessionPrintsNoNotice() {
        let session = TerminalSession(
            host: HostDescriptor(name: "box", hostname: "127.0.0.1", port: 1, username: "u"),
            knownHosts: temporaryKnownHosts())
        let sink = CollectingSink()
        session.attach(sink)
        session.disconnect()
        #expect(session.state == .disconnected("Disconnected"))
        // Not connected before, so no notice is printed.
        #expect(sink.text.isEmpty)
    }
}

/// Opt-in: needs the same TEPFA_TEST_SSH_* environment as the TepfaSSH live tests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEPFA_TEST_SSH_PORT"] != nil))
@MainActor
struct TerminalSessionLiveTests {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var descriptor: HostDescriptor {
        HostDescriptor(
            name: "test-box",
            hostname: env["TEPFA_TEST_SSH_HOST"] ?? "127.0.0.1",
            port: Int(env["TEPFA_TEST_SSH_PORT"] ?? "") ?? 2222,
            username: env["TEPFA_TEST_SSH_USER"] ?? NSUserName(),
            authMethod: .privateKey,
            identity: IdentityDescriptor(name: "test-key", kind: .keyFile, privateKeyPath: env["TEPFA_TEST_SSH_KEY"] ?? ""))
    }

    @Test func firstConnectionPromptsForHostKeyThenRunsAShell() async throws {
        let knownHosts = temporaryKnownHosts()
        let session = TerminalSession(host: descriptor, knownHosts: knownHosts)
        session.overrideShellIntegration(false)
        let sink = CollectingSink()
        session.attach(sink)

        let connecting = Task { await session.connect() }
        try await waitUntil("host key prompt") { session.prompt != nil }
        guard case .hostKey(let key, let verdict, let respond) = session.prompt else {
            Issue.record("expected a host key prompt, got \(String(describing: session.prompt))")
            return
        }
        #expect(verdict == .unknown)
        #expect(key.keyType == "ssh-ed25519")
        respond.resume(returning: true)
        await connecting.value

        #expect(session.state == .connected)
        #expect(session.prompt == nil)
        #expect(session.hostKey == key)
        #expect(await knownHosts.verdict(host: descriptor.hostname, port: descriptor.port, keyType: key.keyType, publicKey: key.openSSHPublicKey) == .known)

        session.resize(cols: 120, rows: 40)
        session.send(ArraySlice("echo tepfa-session-$(tput cols)\n".utf8))
        try await waitUntil("shell output") { sink.text.contains("tepfa-session-120") }

        session.send(ArraySlice("exit\n".utf8))
        try await waitUntil("disconnect") {
            if case .disconnected = session.state { return true }
            return false
        }
        #expect(sink.text.contains("[Session ended]"))

        // Second connection: the key is known, so no prompt.
        let again = Task { await session.connect() }
        try await waitUntil("reconnect") { session.state == .connected }
        #expect(session.prompt == nil)
        await again.value
        session.disconnect()
        #expect(session.state == .disconnected("Disconnected"))
        #expect(sink.text.contains("[Disconnected]"))
    }

    @Test func decliningTheHostKeyFailsTheConnection() async throws {
        let session = TerminalSession(host: descriptor, knownHosts: temporaryKnownHosts())
        let connecting = Task { await session.connect() }
        try await waitUntil("host key prompt") { session.prompt != nil }
        guard case .hostKey(_, _, let respond) = session.prompt else {
            Issue.record("expected a host key prompt")
            return
        }
        respond.resume(returning: false)
        await connecting.value
        guard case .failed(let message) = session.state else {
            Issue.record("expected .failed, got \(session.state)")
            return
        }
        #expect(message.contains("host key"))
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEPFA_TEST_SSH_PORT"] != nil))
@MainActor
struct KeyPusherLiveTests {
    @Test func pushesAKeyOnceAndReportsPresence() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = HostDescriptor(
            name: "test-box",
            hostname: env["TEPFA_TEST_SSH_HOST"] ?? "127.0.0.1",
            port: Int(env["TEPFA_TEST_SSH_PORT"] ?? "") ?? 2222,
            username: env["TEPFA_TEST_SSH_USER"] ?? NSUserName())
        let key = try SSHPrivateKey.load(fromPath: env["TEPFA_TEST_SSH_KEY"] ?? "")
        let credentials = SSHCredentials(username: host.username, secret: .privateKey(key))
        let knownHosts = temporaryKnownHosts()
        // Never touch the real ~/.ssh/authorized_keys from a test.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("tepfa-push-\(UUID().uuidString)/authorized_keys").path
        let pair = try SSHKeyPair.generate(.ed25519, comment: "pushed")

        await #expect(throws: KeyPusher.PushError.self) {
            try await KeyPusher.push(publicKey: pair.openSSHPublicKey, to: host, credentials: credentials, knownHosts: knownHosts, authorizedKeysPath: target)
        }
        let first = try await KeyPusher.push(publicKey: pair.openSSHPublicKey, to: host, credentials: credentials, knownHosts: knownHosts, trustHostKey: true, authorizedKeysPath: target)
        #expect(first == .added)
        let second = try await KeyPusher.push(publicKey: pair.openSSHPublicKey, to: host, credentials: credentials, knownHosts: knownHosts, authorizedKeysPath: target)
        #expect(second == .alreadyPresent)
        let contents = try String(contentsOfFile: target, encoding: .utf8)
        #expect(contents == pair.openSSHPublicKey + "\n")
        try? FileManager.default.removeItem(atPath: (target as NSString).deletingLastPathComponent)
    }
}

/// Opt-in like the other live tests. The test user's login shell on this
/// machine must be bash or zsh for the hooks to be installed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEPFA_TEST_SSH_PORT"] != nil))
@MainActor
struct ShellIntegrationLiveTests {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private func descriptor(startupCommand: String? = nil) -> HostDescriptor {
        HostDescriptor(
            name: "test-box",
            hostname: env["TEPFA_TEST_SSH_HOST"] ?? "127.0.0.1",
            port: Int(env["TEPFA_TEST_SSH_PORT"] ?? "") ?? 2222,
            username: env["TEPFA_TEST_SSH_USER"] ?? NSUserName(),
            authMethod: .privateKey,
            identity: IdentityDescriptor(name: "test-key", kind: .keyFile, privateKeyPath: env["TEPFA_TEST_SSH_KEY"] ?? ""),
            startupCommand: startupCommand)
    }

    private func connect(_ session: TerminalSession) async throws {
        let connecting = Task { await session.connect() }
        try await waitUntil("host key prompt") { session.prompt != nil }
        if case .hostKey(_, _, let respond) = session.prompt { respond.resume(returning: true) }
        await connecting.value
        #expect(session.state == .connected)
    }

    @Test func installedHooksRecordCommandsWithExitStatus() async throws {
        let recorder = InMemoryCommandHistoryRecorder()
        let session = TerminalSession(host: descriptor(), knownHosts: temporaryKnownHosts(), historyRecorder: recorder)
        session.overrideShellIntegration(true)
        let sink = CollectingSink()
        session.attach(sink)
        try await connect(session)

        try await waitUntil("OSC 133 prompt markers", timeout: .seconds(15)) { session.hasShellIntegration }
        #expect(session.promptPhase == .prompt)

        session.sendCommand("false")
        try await waitUntil("first command to finish") { recorder.records.first?.exitStatus != nil }
        session.sendCommand("echo tepfa-$((40+2))")
        try await waitUntil("second command to finish") { recorder.records.count == 2 && recorder.records[1].exitStatus != nil }

        #expect(recorder.records[0].command == "false")
        #expect(recorder.records[0].exitStatus == 1)
        #expect(recorder.records[0].source == .shellIntegration)
        #expect(recorder.records[1].command == "echo tepfa-$((40+2))", "records: \(recorder.records.map(\.command))")
        #expect(recorder.records[1].exitStatus == 0)
        #expect(recorder.records[1].hostName == "test-box")
        #expect(sink.text.contains("tepfa-42"))
        #expect(session.promptPhase == .prompt)
        session.disconnect()
    }

    @Test func startupCommandRunsAfterThePromptAndTypedFallbackRecordsWithoutHooks() async throws {
        let recorder = InMemoryCommandHistoryRecorder()
        let session = TerminalSession(host: descriptor(startupCommand: "echo tepfa-startup-$((1+1))"), knownHosts: temporaryKnownHosts(), historyRecorder: recorder)
        session.overrideShellIntegration(false)
        let sink = CollectingSink()
        session.attach(sink)
        try await connect(session)

        try await waitUntil("startup command output") { sink.text.contains("tepfa-startup-2") }
        #expect(!session.hasShellIntegration)
        try await waitUntil("typed record") { recorder.records.count == 1 }
        #expect(recorder.records.first?.command == "echo tepfa-startup-$((1+1))")
        #expect(recorder.records.first?.source == .typed)
        #expect(recorder.records.first?.exitStatus == nil)

        // Keystrokes the tty does not echo (a password prompt) are not recorded.
        session.sendCommand("stty -echo; read -r secret; stty echo; echo done-$secret")
        try await waitUntil("stty command recorded") { recorder.records.count == 2 }
        try? await Task.sleep(for: .milliseconds(400))
        for character in "hunter2\r" { session.send(text: String(character)) }
        try await waitUntil("read to finish") { sink.text.contains("done-hunter2") }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.records.count == 2)
        #expect(!recorder.records.contains { $0.command.contains("hunter2") })

        // Keystrokes the tty echoes are recorded once Enter arrives.
        for character in "echo typed-$((2+2))" { session.send(text: String(character)) }
        try await waitUntil("echo of the typed text") { sink.text.contains("echo typed-$((2+2))") }
        session.send(text: "\r")
        try await waitUntil("typed command recorded") { recorder.records.count == 3 }
        #expect(recorder.records[2].command == "echo typed-$((2+2))")
        session.disconnect()
    }
}
