import Foundation
import Testing
import TepfaCore
import TepfaSSH
@testable import TepfaTerminal

/// Opt-in: needs the same TEPFA_TEST_SSH_* environment as the TepfaSSH live tests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEPFA_TEST_SSH_PORT"] != nil))
@MainActor
struct AgentLogSessionLiveTests {
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

    private func knownHosts() -> KnownHostsStore {
        KnownHostsStore(url: FileManager.default.temporaryDirectory
            .appending(path: "tepfa-agent-log-tests-\(UUID().uuidString)")
            .appending(path: "known_hosts.json"))
    }

    private func trustHostKey(_ session: TerminalSession) async throws {
        let connecting = Task { await session.connect() }
        try await waitUntil("host key prompt") { session.prompt != nil }
        if case .hostKey(_, _, let respond) = session.prompt { respond.resume(returning: true) }
        await connecting.value
        #expect(session.state == .connected)
    }

    @Test func agentLogRunsCommandsWithoutAShell() async throws {
        let session = TerminalSession(host: descriptor, mode: .agentLog, knownHosts: knownHosts())
        #expect(session.title == "Agent · test-box")
        let sink = CollectingSink()
        session.attach(sink)
        try await trustHostKey(session)

        let result = try await session.runCommand("echo hi; echo err >&2; exit 3")
        #expect(result.exitStatus == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
        #expect(sink.text.contains("$ echo hi; echo err >&2; exit 3"))
        #expect(sink.text.contains("hi\r\n"))
        #expect(sink.text.contains("[exit 3]"))

        // Typing into an agent log does nothing: there is no PTY behind it.
        session.send(ArraySlice("exit\n".utf8))
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.state == .connected)

        let stdin = try await session.runCommand("cat", stdin: Array("piped input".utf8), echo: false)
        #expect(String(decoding: stdin.stdout, as: UTF8.self) == "piped input")
        #expect(!sink.text.contains("piped input"))
        session.disconnect()
    }

    @Test func cancellingRunCommandStopsTheRemoteCommand() async throws {
        let session = TerminalSession(host: descriptor, mode: .agentLog, knownHosts: knownHosts())
        try await trustHostKey(session)
        let started = ContinuousClock.now
        let running = Task { try await session.runCommand("sleep 30; echo done") }
        try await Task.sleep(for: .milliseconds(300))
        running.cancel()
        do {
            _ = try await running.value
            Issue.record("expected the cancelled command to throw")
        } catch {
            #expect(ContinuousClock.now - started < .seconds(5), "cancellation should not wait for sleep to finish: \(error)")
        }
        // The connection is reopened for the next command.
        let after = try await session.runCommand("echo again")
        #expect(String(decoding: after.stdout, as: UTF8.self) == "again\n")
        session.disconnect()
    }

    @Test func workspaceReusesAgentTabsAndLeavesThemOutOfSnapshots() async throws {
        let store = knownHosts()
        let descriptor = self.descriptor  // one UUID for the whole test
        let workspace = Workspace(
            makeSession: { TerminalSession(host: $0, knownHosts: store) },
            makeAgentSession: { TerminalSession(host: $0, mode: .agentLog, knownHosts: store) })
        let shell = workspace.openTab(host: descriptor, connect: false)
        let agent = workspace.openAgentTab(host: descriptor)
        try await waitUntil("host key prompt") { agent.prompt != nil }
        if case .hostKey(_, _, let respond) = agent.prompt { respond.resume(returning: true) }
        try await waitUntil("agent connected") { agent.state == .connected }

        #expect(workspace.tabs.count == 2)
        #expect(workspace.selectedTabID == workspace.tabs.last?.id)
        #expect(workspace.isAgentTab(workspace.tabs[1]))
        #expect(!workspace.isAgentTab(workspace.tabs[0]))
        #expect(workspace.agentSession(forHost: descriptor.id) === agent)

        workspace.select(tabID: workspace.tabs[0].id)
        #expect(workspace.openAgentTab(host: descriptor) === agent)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.selectedTabID == workspace.tabs[1].id)

        let snapshot = workspace.snapshot()
        #expect(snapshot.tabs.count == 1)
        #expect(Array(snapshot.sessionHosts.keys) == [shell.id])
        #expect(snapshot.transientHosts.isEmpty)
        agent.disconnect()
    }
}
