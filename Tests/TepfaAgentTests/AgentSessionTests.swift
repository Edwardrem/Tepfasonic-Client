import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("Tool runner and agent loop")
@MainActor
struct AgentSessionTests {
    private func makeSession(_ host: FakeToolHost, responses: [LLMResponse]) -> (AgentSession, FakeProvider) {
        let provider = FakeProvider(responses: responses)
        let runner = AgentToolRunner(host: host, source: .agentPanel, conversationID: UUID())
        let session = AgentSession(provider: provider, systemPrompt: "sys", toolRunner: runner)
        return (session, provider)
    }

    private func waitUntilDone(_ session: AgentSession) async {
        for _ in 0..<400 where session.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.isRunning)
    }

    @Test func askModeRunsAfterApproval() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web, FakeToolHost.db])
        let (session, provider) = makeSession(host, responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "df -h", "reason": "check disk"], text: "Let me look."),
            FakeProvider.reply("Disk is fine."),
        ])
        session.send("is web-01 low on disk?")
        await waitUntilDone(session)

        #expect(host.approvalRequests.map(\.command) == ["df -h"])
        #expect(host.approvalRequests.first?.reason == "check disk")
        #expect(host.approvalRequests.first?.isDestructive == false)
        #expect(host.executed.map(\.command) == ["df -h"])
        #expect(session.messages.count == 4)
        guard case .toolResult(let id, let content, let isError)? = session.messages[2].blocks.first else { Issue.record("no tool result"); return }
        #expect(id == "t1")
        #expect(!isError)
        #expect(content.hasPrefix("<command_output host=\"web-01\" exit_status=\"0\""))
        #expect(content.contains("ran: df -h"))
        #expect(session.messages[3].text == "Disk is fine.")
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].messages.count == 3)
        #expect(host.auditRecords.map(\.decision) == [.approved])
        #expect(host.auditRecords.first?.exitStatus == 0)
        #expect(host.auditRecords.first?.source == .agentPanel)
        #expect(session.usage.inputTokens == 20)
        #expect(session.lastError == nil)
    }

    @Test func readOnlyHostBlocksWithoutAsking() async {
        let host = FakeToolHost(hosts: [FakeToolHost.db])
        let (session, _) = makeSession(host, responses: [
            FakeProvider.toolCall(.runCommand, ["host": "db-01", "command": "rm -rf /var/lib/postgresql", "reason": "cleanup"]),
            FakeProvider.reply("ok"),
        ])
        session.send("clean up")
        await waitUntilDone(session)
        #expect(host.approvalRequests.isEmpty)
        #expect(host.executed.isEmpty)
        guard case .toolResult(_, let content, let isError)? = session.messages[2].blocks.first else { Issue.record("no tool result"); return }
        #expect(isError)
        #expect(content.contains("read-only"))
        #expect(host.auditRecords.map(\.decision) == [.blocked])
    }

    @Test func allowlistRunsMatchingCommandsUnattended() async {
        let host = FakeToolHost(hosts: [FakeToolHost.lab])
        let (session, _) = makeSession(host, responses: [
            FakeProvider.toolCall(.runCommand, ["host": "lab", "command": "df -h /", "reason": "disk"]),
            FakeProvider.toolCall(.runCommand, id: "t2", ["host": "lab", "command": "systemctl restart nginx && rm -rf /tmp/x", "reason": "restart"]),
            FakeProvider.reply("done"),
        ])
        host.approval = { _ in .denied }
        session.send("go")
        await waitUntilDone(session)
        #expect(host.executed.map(\.command) == ["df -h /"])
        #expect(host.approvalRequests.map(\.command) == ["systemctl restart nginx && rm -rf /tmp/x"])
        #expect(host.approvalRequests.first?.isDestructive == true)
        #expect(host.auditRecords.map(\.decision) == [.autoAllowed, .denied])
        guard case .toolResult(_, let content, let isError)? = session.messages[4].blocks.first else { Issue.record("no tool result"); return }
        #expect(isError)
        #expect(content.contains("denied"))
    }

    @Test func editedCommandRunsAndIsAudited() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in .edited("df -h /srv") }
        let (session, _) = makeSession(host, responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "df -h", "reason": "disk"]),
            FakeProvider.reply("ok"),
        ])
        session.send("go")
        await waitUntilDone(session)
        #expect(host.executed.map(\.command) == ["df -h /srv"])
        #expect(host.auditRecords.first?.decision == .edited)
        #expect(host.auditRecords.first?.command == "df -h /srv")
        #expect(host.auditRecords.first?.proposedCommand == "df -h")
    }

    @Test func fileToolsUseCatWithQuotedPaths() async throws {
        let host = FakeToolHost(hosts: [FakeToolHost.lab])
        host.executor = { _, command, stdin in
            if command.hasPrefix("head -c") { return AgentCommandOutput(stdout: Data("server {\n}\n".utf8), stderr: Data(), exitStatus: 0, duration: .milliseconds(1)) }
            if command.hasPrefix("cat --") { return AgentCommandOutput(stdout: Data([0, 1, 2, 255]), stderr: Data(), exitStatus: 0, duration: .milliseconds(1)) }
            return AgentCommandOutput(stdout: Data(), stderr: Data(), exitStatus: 0, duration: .milliseconds(1))
        }
        let temp = FileManager.default.temporaryDirectory.appending(path: "tepfa-agent-\(UUID().uuidString)")
        let download = temp.appending(path: "nested/out.bin")
        let upload = temp.appending(path: "up.txt")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: upload)
        defer { try? FileManager.default.removeItem(at: temp) }

        let runner = AgentToolRunner(host: host, source: .mcp)
        let read = await runner.call(name: "read_file", input: ["host": "lab", "path": "~/it's.conf"])
        #expect(!read.isError)
        #expect(read.content.contains("server {"))
        #expect(host.executed.last?.command == #"head -c 65537 -- "$HOME"/'it'\''s.conf'"#)
        #expect(host.executed.last?.echo == .commandOnly)

        let write = await runner.call(name: "write_file", input: ["host": "lab", "path": "/srv/app/config.yml", "contents": "a: 1\n", "mode": "0644", "reason": "configure"])
        #expect(!write.isError, Comment(rawValue: write.content))
        #expect(host.executed.last?.command == "cat > '/srv/app/config.yml' && chmod 0644 '/srv/app/config.yml'")
        #expect(host.executed.last?.stdin == Data("a: 1\n".utf8))
        #expect(host.approvalRequests.map(\.tool) == ["read_file"], "the read asked (not allowlisted); the allowlisted write ran without asking")
        #expect(host.approvalRequests.first?.command.hasPrefix("head -c") == true)

        let asked = await runner.call(name: "write_file", input: ["host": "lab", "path": "/etc/hosts", "contents": "x", "reason": "r"])
        #expect(host.approvalRequests.map(\.tool) == ["read_file", "write_file"], "writes outside the allowlist ask")
        #expect(host.approvalRequests.last?.command.hasPrefix("cat > '/etc/hosts'") == true)
        #expect(!asked.isError)

        let down = await runner.call(name: "sftp_transfer", input: ["host": "lab", "direction": "download", "remote_path": "/var/backups/x.bin", "local_path": .string(download.path), "reason": "backup"])
        #expect(!down.isError, Comment(rawValue: down.content))
        #expect(try Data(contentsOf: download) == Data([0, 1, 2, 255]))

        let up = await runner.call(name: "sftp_transfer", input: ["host": "lab", "direction": "upload", "remote_path": "/srv/app/up.txt", "local_path": .string(upload.path), "reason": "deploy"])
        #expect(!up.isError, Comment(rawValue: up.content))
        #expect(host.executed.last?.command == "cat > '/srv/app/up.txt'")
        #expect(host.executed.last?.stdin == Data("payload".utf8))

        let missing = await runner.call(name: "sftp_transfer", input: ["host": "lab", "direction": "upload", "remote_path": "/x", "local_path": .string(temp.appending(path: "nope").path), "reason": "r"])
        #expect(missing.isError)
        #expect(host.auditRecords.map(\.tool) == ["read_file", "write_file", "write_file", "sftp_transfer", "sftp_transfer"])
    }

    @Test func hostResolutionAndListing() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web, FakeToolHost.db, FakeToolHost.lab])
        host.buffers[FakeToolHost.web.id] = "$ tail -f /var/log/nginx/error.log\n2026/11/03 upstream timed out"
        let runner = AgentToolRunner(host: host, source: .agentPanel)
        let list = await runner.call(name: "list_hosts", input: [:])
        #expect(list.content.contains("- web-01: ubuntu@10.0.0.5; group Prod; tags nginx; permission ask; no terminal open"))
        #expect(list.content.contains("- lab: me@lab.local:2222; permission allowlist; allowlist df * | systemctl restart * | write_file /srv/app/*"))

        let byTarget = await runner.call(name: "read_terminal_buffer", input: ["host": "ubuntu@10.0.0.5"])
        #expect(byTarget.content.contains("<terminal_buffer host=\"web-01\" lines=\"2\">"))
        let byPartial = await runner.call(name: "read_terminal_buffer", input: ["host": "DB"])
        #expect(byPartial.content == "No terminal is open on db-01.")
        let byID = await runner.call(name: "read_terminal_buffer", input: ["host": .string(FakeToolHost.lab.id.uuidString)])
        #expect(byID.content == "No terminal is open on lab.")
        let unknown = await runner.call(name: "run_command", input: ["host": "mail", "command": "ls", "reason": "r"])
        #expect(unknown.isError)
        #expect(unknown.content.contains("No saved host matches \"mail\""))
        let badTool = await runner.call(name: "format_disk", input: [:])
        #expect(badTool.isError)
        let missingArgument = await runner.call(name: "run_command", input: ["host": "web-01"])
        #expect(missingArgument.content.contains("\"command\""))
    }

    @Test func stopDuringApprovalCancels() async {
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        host.approval = { _ in
            // Behaves like the app's sheet: waits until the task is cancelled.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .denied
        }
        let (session, _) = makeSession(host, responses: [
            FakeProvider.toolCall(.runCommand, ["host": "web-01", "command": "uptime", "reason": "load"]),
            FakeProvider.reply("never reached"),
        ])
        session.send("go")
        for _ in 0..<200 where host.approvalRequests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        session.stop()
        await waitUntilDone(session)
        #expect(host.executed.isEmpty)
        #expect(session.lastError == "Stopped.")
        #expect(host.auditRecords.map(\.decision) == [.cancelled])
        guard case .toolResult(_, _, let isError)? = session.messages.last?.blocks.first else { Issue.record("transcript ends with the tool result"); return }
        #expect(isError)
        #expect(session.canSend)
    }

    @Test func maxTokensAndRefusalStopTheLoop() async {
        let host = FakeToolHost(hosts: [])
        let (session, _) = makeSession(host, responses: [FakeProvider.reply("partial", stop: .maxTokens)])
        session.send("hi")
        await waitUntilDone(session)
        #expect(session.lastError?.contains("output limit") == true)

        let (refusing, _) = makeSession(host, responses: [LLMResponse(message: AgentMessage(role: .assistant, blocks: []), stopReason: .refusal, model: "m", usage: LLMUsage(), refusalCategory: "cyber")])
        refusing.send("hi")
        await waitUntilDone(refusing)
        #expect(refusing.lastError == "The model declined to continue (cyber).")
    }

    @Test func systemPromptNamesHostsAndFocus() {
        let prompt = AgentSystemPrompt.build(hosts: [FakeToolHost.web, FakeToolHost.db], focus: FakeToolHost.web)
        #expect(prompt.contains("- web-01: ubuntu@10.0.0.5, ask, group Prod"))
        #expect(prompt.contains("- db-01: postgres@10.0.0.6, read-only"))
        #expect(prompt.contains("This conversation is about the host \"web-01\""))
        #expect(prompt.contains("<command_output>"))
    }
}
