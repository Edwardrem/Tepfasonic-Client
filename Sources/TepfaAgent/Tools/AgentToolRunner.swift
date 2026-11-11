import Foundation
import TepfaCore

/// Executes tool calls with the guardrails: resolves the host, decides
/// whether to ask, runs the command through the host, writes the audit log
/// and wraps the output as untrusted data for the model.
@MainActor
public final class AgentToolRunner {
    public struct Result: Sendable, Equatable {
        public var content: String
        public var isError: Bool

        public init(content: String, isError: Bool) {
            self.content = content
            self.isError = isError
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case unknownTool(String)
        case missingArgument(String)
        case unknownHost(String)
        case denied(String)
        case blocked(String)
        case cancelled
        case localFile(String)
        case document(String)

        public var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown tool \(name)."
            case .missingArgument(let name): "Missing argument \"\(name)\"."
            case .unknownHost(let name): "No saved host matches \"\(name)\". Call list_hosts to see the names."
            case .denied(let reason): "The user denied this action. \(reason)".trimmingCharacters(in: .whitespaces)
            case .blocked(let reason): "Not allowed: \(reason)"
            case .cancelled: "The action was cancelled."
            case .localFile(let detail): detail
            case .document(let detail): detail
            }
        }
    }

    public let host: any AgentToolHost
    public let source: AgentActionSource
    public var conversationID: UUID?
    /// Bytes of stdout/stderr passed to the model per command.
    public var outputLimit = 48 * 1024
    public var defaultTimeout: Duration = .seconds(120)
    /// Where `create_document` writes: `Agent/Documents` under the app's data folder.
    public var documentsDirectory: URL = AppPaths.applicationSupport.appending(path: "Agent/Documents", directoryHint: .isDirectory)

    public init(host: any AgentToolHost, source: AgentActionSource, conversationID: UUID? = nil) {
        self.host = host
        self.source = source
        self.conversationID = conversationID
    }

    /// Runs one tool call. Errors become results with `isError` so the model can react.
    public func call(name: String, input: JSONValue) async -> Result {
        do {
            return Result(content: try await dispatch(name: name, input: input), isError: false)
        } catch is CancellationError {
            return Result(content: Failure.cancelled.localizedDescription, isError: true)
        } catch {
            return Result(content: error.localizedDescription, isError: true)
        }
    }

    private func dispatch(name: String, input: JSONValue) async throws -> String {
        guard let tool = AgentToolName(rawValue: name) else { throw Failure.unknownTool(name) }
        switch tool {
        case .listHosts:
            return listHosts()
        case .runCommand:
            let target = try resolveHost(try string("host", in: input))
            let command = try string("command", in: input)
            let reason = input["reason"]?.stringValue ?? ""
            let timeout = Duration.seconds(min(max(input["timeout_seconds"]?.intValue ?? 120, 1), 600))
            return try await runCommand(on: target, command: command, reason: reason, timeout: timeout)
        case .readFile:
            let target = try resolveHost(try string("host", in: input))
            let path = try string("path", in: input)
            let maxBytes = min(max(input["max_bytes"]?.intValue ?? 65_536, 1), 1_048_576)
            return try await readFile(on: target, path: path, maxBytes: maxBytes)
        case .writeFile:
            let target = try resolveHost(try string("host", in: input))
            let path = try string("path", in: input)
            let contents = try string("contents", in: input)
            let append = input["append"]?.boolValue ?? false
            let mode = input["mode"]?.stringValue
            let reason = input["reason"]?.stringValue ?? ""
            return try await writeFile(on: target, path: path, contents: Data(contents.utf8), append: append, mode: mode, reason: reason)
        case .sftpTransfer:
            let target = try resolveHost(try string("host", in: input))
            guard let direction = AgentTransferDirection(rawValue: try string("direction", in: input)) else { throw Failure.missingArgument("direction (upload or download)") }
            let remote = try string("remote_path", in: input)
            let local = try string("local_path", in: input)
            let reason = input["reason"]?.stringValue ?? ""
            return try await transfer(on: target, direction: direction, remotePath: remote, localPath: local, reason: reason)
        case .readTerminalBuffer:
            let target = try resolveHost(try string("host", in: input))
            let maxLines = min(max(input["max_lines"]?.intValue ?? 200, 1), 2000)
            guard let buffer = host.terminalBuffer(on: target, maxLines: maxLines) else {
                return "No terminal is open on \(target.name)."
            }
            return "<terminal_buffer host=\"\(xmlEscape(target.name))\" lines=\"\(buffer.split(separator: "\n", omittingEmptySubsequences: false).count)\">\n\(buffer)\n</terminal_buffer>"
        case .createDocument:
            let fileName = try string("file_name", in: input)
            guard let format = DocumentFormat(rawValue: (input["format"]?.stringValue ?? "").lowercased().trimmingCharacters(in: .whitespaces)) else {
                throw Failure.missingArgument("format (pdf, docx, html, md, txt or csv)")
            }
            let content = try string("content", in: input)
            return try createDocument(fileName: fileName, format: format, title: input["title"]?.stringValue, content: content)
        }
    }

    // MARK: Documents

    /// Renders the Markdown into `documentsDirectory`, never overwriting an earlier file.
    public func createDocument(fileName: String, format: DocumentFormat, title: String?, content: String) throws -> String {
        let stem = Self.documentStem(fileName, format: format)
        do {
            try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        } catch {
            throw Failure.document("Could not create \(documentsDirectory.path): \(error.localizedDescription)")
        }
        var url = documentsDirectory.appending(path: "\(stem).\(format.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = documentsDirectory.appending(path: "\(stem) \(counter).\(format.fileExtension)")
            counter += 1
        }
        let rendered: RenderedDocument
        do {
            rendered = try DocumentRenderer.render(markdown: content, title: title, format: format, to: url)
        } catch {
            throw Failure.document(error.localizedDescription)
        }
        let reference = AgentDocumentReference(path: url.path, name: url.lastPathComponent, format: format, byteCount: rendered.byteCount, pageCount: rendered.pageCount)
        return "Created \(reference.name) (\(reference.summary)) at \(url.path). The user sees it as a card with Open, Show in Finder and Save As…; tell them it is ready and summarise what it contains.\n\(reference.tag)"
    }

    /// A safe file stem: no directories, no control characters, no doubled extension.
    static func documentStem(_ name: String, format: DocumentFormat) -> String {
        var stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stem = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        stem = stem.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        let lowered = stem.lowercased()
        for ext in DocumentFormat.allCases.map(\.fileExtension) where lowered.hasSuffix("." + ext) {
            stem = String(stem.dropLast(ext.count + 1))
            break
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.isEmpty { stem = "Document" }
        return String(stem.prefix(120))
    }

    // MARK: Tools

    private func listHosts() -> String {
        let hosts = host.hosts()
        guard !hosts.isEmpty else { return "No hosts are saved in Tepfasonic." }
        var lines = ["\(hosts.count) saved host(s):"]
        for info in hosts.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            var parts = ["- \(info.name): \(info.target)"]
            if let group = info.group { parts.append("group \(group)") }
            if !info.tags.isEmpty { parts.append("tags " + info.tags.joined(separator: ", ")) }
            parts.append("permission \(info.permission.rawValue)")
            if info.permission == .allowlist { parts.append("allowlist " + (info.allowlist.isEmpty ? "(empty)" : info.allowlist.joined(separator: " | "))) }
            parts.append(info.isConnected ? "terminal connected" : "no terminal open")
            parts.append("id \(info.id.uuidString)")
            lines.append(parts.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private func runCommand(on target: AgentHostInfo, command: String, reason: String, timeout: Duration) async throws -> String {
        let verdict = CommandGuard.decide(command: command, mode: target.permission, allowlist: target.allowlist)
        let (effective, decision, detail) = try await resolve(verdict, tool: .runCommand, on: target, command: command, reason: reason)
        let started = ContinuousClock.now
        do {
            let output = try await host.execute(on: target, command: effective, stdin: Data(), timeout: timeout, echo: .full, source: source)
            record(tool: .runCommand, on: target, command: effective, proposed: effective == command ? nil : command, reason: reason, decision: decision, detail: detail, output: output)
            return format(output, host: target, command: effective)
        } catch {
            record(tool: .runCommand, on: target, command: effective, proposed: effective == command ? nil : command, reason: reason, decision: error is CancellationError || isCancellation(error) ? .cancelled : decision, detail: detail, output: nil, failure: error.localizedDescription, since: started)
            throw error
        }
    }

    private func readFile(on target: AgentHostInfo, path: String, maxBytes: Int) async throws -> String {
        let command = "head -c \(maxBytes + 1) -- \(quotedRemote(path))"
        let verdict = CommandGuard.decide(action: "read_file \(path)", readOnly: true, mode: target.permission, allowlist: target.allowlist)
        let (_, decision, detail) = try await resolve(verdict, tool: .readFile, on: target, command: command, reason: "Read \(path)")
        let output = try await host.execute(on: target, command: command, stdin: Data(), timeout: defaultTimeout, echo: .commandOnly, source: source)
        record(tool: .readFile, on: target, command: command, reason: "Read \(path)", decision: decision, detail: detail, output: output)
        guard output.exitStatus == 0 else {
            return "Could not read \(path) on \(target.name) (exit \(output.exitStatus.map(String.init) ?? "?")): \(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        let truncated = output.stdout.count > maxBytes
        let text = String(decoding: output.stdout.prefix(maxBytes), as: UTF8.self)
        return "<file host=\"\(xmlEscape(target.name))\" path=\"\(xmlEscape(path))\" bytes=\"\(min(output.stdout.count, maxBytes))\" truncated=\"\(truncated)\">\n\(text)\n</file>"
    }

    private func writeFile(on target: AgentHostInfo, path: String, contents: Data, append: Bool, mode: String?, reason: String) async throws -> String {
        let quoted = quotedRemote(path)
        var command = "cat \(append ? ">>" : ">") \(quoted)"
        if let mode, mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil { command += " && chmod \(mode) \(quoted)" }
        let verdict = CommandGuard.decide(action: "write_file \(path)", readOnly: false, mode: target.permission, allowlist: target.allowlist)
        let (_, decision, detail) = try await resolve(verdict, tool: .writeFile, on: target, command: "\(command)  # \(contents.count == 1 ? "1 byte" : "\(contents.count) bytes")", reason: reason)
        let output = try await host.execute(on: target, command: command, stdin: contents, timeout: defaultTimeout, echo: .commandOnly, source: source)
        record(tool: .writeFile, on: target, command: command, reason: reason, decision: decision, detail: detail, output: output)
        guard output.exitStatus == 0 else {
            return "Writing \(path) on \(target.name) failed (exit \(output.exitStatus.map(String.init) ?? "?")): \(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "Wrote \(contents.count) bytes to \(path) on \(target.name)\(append ? " (appended)" : "")."
    }

    private func transfer(on target: AgentHostInfo, direction: AgentTransferDirection, remotePath: String, localPath: String, reason: String) async throws -> String {
        let localURL = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
        let quoted = quotedRemote(remotePath)
        switch direction {
        case .download:
            let command = "cat -- \(quoted)"
            let verdict = CommandGuard.decide(action: "sftp_transfer download \(remotePath)", readOnly: true, mode: target.permission, allowlist: target.allowlist)
            let (_, decision, detail) = try await resolve(verdict, tool: .sftpTransfer, on: target, command: "\(command)  # download to \(localURL.path)", reason: reason)
            let output = try await host.execute(on: target, command: command, stdin: Data(), timeout: .seconds(600), echo: .commandOnly, source: source)
            record(tool: .sftpTransfer, on: target, command: "download \(remotePath) -> \(localURL.path)", reason: reason, decision: decision, detail: detail, output: output)
            guard output.exitStatus == 0 else {
                return "Download of \(remotePath) from \(target.name) failed (exit \(output.exitStatus.map(String.init) ?? "?")): \(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            do {
                try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try output.stdout.write(to: localURL, options: [.atomic])
            } catch {
                throw Failure.localFile("Could not write \(localURL.path): \(error.localizedDescription)")
            }
            return "Downloaded \(output.stdout.count) bytes from \(target.name):\(remotePath) to \(localURL.path)."
        case .upload:
            let data: Data
            do { data = try Data(contentsOf: localURL) } catch { throw Failure.localFile("Could not read \(localURL.path): \(error.localizedDescription)") }
            let command = "cat > \(quoted)"
            let verdict = CommandGuard.decide(action: "sftp_transfer upload \(remotePath)", readOnly: false, mode: target.permission, allowlist: target.allowlist)
            let (_, decision, detail) = try await resolve(verdict, tool: .sftpTransfer, on: target, command: "\(command)  # upload \(data.count) bytes from \(localURL.path)", reason: reason)
            let output = try await host.execute(on: target, command: command, stdin: data, timeout: .seconds(600), echo: .commandOnly, source: source)
            record(tool: .sftpTransfer, on: target, command: "upload \(localURL.path) -> \(remotePath)", reason: reason, decision: decision, detail: detail, output: output)
            guard output.exitStatus == 0 else {
                return "Upload to \(target.name):\(remotePath) failed (exit \(output.exitStatus.map(String.init) ?? "?")): \(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return "Uploaded \(data.count) bytes from \(localURL.path) to \(target.name):\(remotePath)."
        }
    }

    // MARK: Guardrails

    /// Applies the verdict, asking the user when needed. Returns the command to
    /// run (edited or not), the audit decision and the guardrail detail.
    private func resolve(_ verdict: CommandGuard.Verdict, tool: AgentToolName, on target: AgentHostInfo, command: String, reason: String) async throws -> (String, AgentAuditDecision, String) {
        switch verdict {
        case .allow(let why):
            return (command, .autoAllowed, why)
        case .deny(let why):
            recordNotRun(tool: tool, on: target, command: command, reason: reason, decision: .blocked, detail: why)
            throw Failure.blocked(why)
        case .ask(let why):
            let request = AgentApprovalRequest(
                source: source, host: target, tool: tool.rawValue, command: command, reason: reason, detail: why,
                isDestructive: CommandGuard.destructiveMatch(command) != nil)
            let response = await host.approve(request)
            if Task.isCancelled {
                recordNotRun(tool: tool, on: target, command: command, reason: reason, decision: .cancelled, detail: why)
                throw CancellationError()
            }
            switch response {
            case .approved:
                return (command, .approved, why)
            case .edited(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    recordNotRun(tool: tool, on: target, command: command, reason: reason, decision: .denied, detail: "edited to an empty command")
                    throw Failure.denied("")
                }
                return (trimmed, .edited, why)
            case .denied:
                recordNotRun(tool: tool, on: target, command: command, reason: reason, decision: .denied, detail: why)
                throw Failure.denied("Do not retry it unchanged; ask the user how to proceed if it is needed.")
            }
        }
    }

    private func resolveHost(_ reference: String) throws -> AgentHostInfo {
        let hosts = host.hosts()
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = hosts.first(where: { $0.name == needle }) { return match }
        if let id = UUID(uuidString: needle), let match = hosts.first(where: { $0.id == id }) { return match }
        if let match = hosts.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) { return match }
        if let match = hosts.first(where: { $0.target == needle || $0.hostname == needle || "\($0.username)@\($0.hostname)" == needle }) { return match }
        let lower = needle.lowercased()
        let partial = hosts.filter { $0.name.lowercased().contains(lower) || $0.hostname.lowercased().contains(lower) }
        if partial.count == 1 { return partial[0] }
        throw Failure.unknownHost(needle)
    }

    // MARK: Audit and formatting

    private func record(tool: AgentToolName, on target: AgentHostInfo, command: String, proposed: String? = nil, reason: String, decision: AgentAuditDecision, detail: String, output: AgentCommandOutput?, failure: String? = nil, since: ContinuousClock.Instant? = nil) {
        var excerpt = ""
        if let output {
            excerpt = String(output.stdoutText.prefix(2000))
            if !output.stderr.isEmpty { excerpt += (excerpt.isEmpty ? "" : "\n") + "stderr: " + String(output.stderrText.prefix(1000)) }
        } else if let failure {
            excerpt = "failed: \(failure)"
        }
        let duration = output?.duration ?? since.map { ContinuousClock.now - $0 }
        host.audit(AgentAuditRecord(
            source: source, hostID: target.id, hostName: target.name, hostTarget: target.target, tool: tool.rawValue,
            command: command, proposedCommand: proposed, reason: reason, decision: decision, decisionDetail: detail,
            exitStatus: output?.exitStatus, durationMilliseconds: duration.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) },
            outputExcerpt: excerpt, conversationID: conversationID))
    }

    private func recordNotRun(tool: AgentToolName, on target: AgentHostInfo, command: String, reason: String, decision: AgentAuditDecision, detail: String) {
        host.audit(AgentAuditRecord(
            source: source, hostID: target.id, hostName: target.name, hostTarget: target.target, tool: tool.rawValue,
            command: command, reason: reason, decision: decision, decisionDetail: detail, conversationID: conversationID))
    }

    /// Wraps output so the model treats it as data from the host, never as instructions.
    func format(_ output: AgentCommandOutput, host target: AgentHostInfo, command: String) -> String {
        let stdout = clip(output.stdout)
        let stderr = clip(output.stderr)
        let status = output.exitStatus.map(String.init) ?? (output.signal.map { "signal \($0)" } ?? "unknown")
        var text = "<command_output host=\"\(xmlEscape(target.name))\" exit_status=\"\(status)\" duration_ms=\"\(output.duration.components.seconds * 1000 + output.duration.components.attoseconds / 1_000_000_000_000_000)\" truncated=\"\(stdout.truncated || stderr.truncated)\">\n"
        text += stdout.text
        if !stderr.text.isEmpty {
            text += (stdout.text.isEmpty || stdout.text.hasSuffix("\n") ? "" : "\n") + "--- stderr ---\n" + stderr.text
        }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "</command_output>"
        return text
    }

    private func clip(_ data: Data) -> (text: String, truncated: Bool) {
        if data.count <= outputLimit { return (String(decoding: data, as: UTF8.self), false) }
        let head = data.prefix(outputLimit * 3 / 4)
        let tail = data.suffix(outputLimit / 4)
        return (String(decoding: head, as: UTF8.self) + "\n… [\(data.count - head.count - tail.count) bytes omitted] …\n" + String(decoding: tail, as: UTF8.self), true)
    }

    private func string(_ key: String, in input: JSONValue) throws -> String {
        guard let value = input[key]?.stringValue, !value.isEmpty else { throw Failure.missingArgument(key) }
        return value
    }

    /// Quotes a remote path for the shell; `~` and `~/…` expand to the login home.
    func quotedRemote(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + ShellWords.quote(String(path.dropFirst(2))) }
        return ShellWords.quote(path)
    }

    private func isCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled || String(describing: error).contains("cancelled")
    }

    private func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
