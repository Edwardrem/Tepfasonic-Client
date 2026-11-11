import Foundation

/// The tools the agent (and MCP clients) can call.
public enum AgentToolName: String, CaseIterable, Sendable {
    case listHosts = "list_hosts"
    case runCommand = "run_command"
    case readFile = "read_file"
    case writeFile = "write_file"
    case sftpTransfer = "sftp_transfer"
    case readTerminalBuffer = "read_terminal_buffer"
    case createDocument = "create_document"
}

/// One tool as the model and MCP clients see it.
public struct AgentToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema for the input object.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum AgentTools {
    public static let hostParameter: JSONValue = [
        "type": "string",
        "description": "The saved host to use: its name as shown in Tepfasonic, its id from list_hosts, or user@hostname.",
    ]

    public static let all: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: AgentToolName.listHosts.rawValue,
            description: "Lists the servers saved in Tepfasonic with their group, tags, whether a terminal is connected, and the permission mode that applies to agent commands on each (read-only, ask, or allowlist). Call this first when the user names a server loosely.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false]),
        AgentToolDefinition(
            name: AgentToolName.runCommand.rawValue,
            description: "Runs one shell command on a saved host over SSH, without a PTY, and returns its stdout, stderr and exit status. Each call starts a fresh shell: working directory and variables do not carry over, so use absolute paths or `cd dir && command`. Commands must be non-interactive (use -y, --no-pager, DEBIAN_FRONTEND=noninteractive). Depending on the host's permission mode the user may be asked to approve the command first; destructive commands always ask. Give a short, honest reason: it is shown to the user in the approval sheet.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "host": hostParameter,
                    "command": ["type": "string", "description": "The exact command line to run with the login shell."],
                    "reason": ["type": "string", "description": "One line explaining why this command is needed, shown to the user."],
                    "timeout_seconds": ["type": "integer", "description": "Seconds to wait before the command is stopped. Default 120, maximum 600.", "minimum": 1, "maximum": 600],
                ],
                "required": ["host", "command", "reason"],
                "additionalProperties": false,
            ]),
        AgentToolDefinition(
            name: AgentToolName.readFile.rawValue,
            description: "Reads a text file from a host and returns its contents (truncated at max_bytes). Counts as a read-only command on the host.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "host": hostParameter,
                    "path": ["type": "string", "description": "Absolute path, or relative to the login user's home."],
                    "max_bytes": ["type": "integer", "description": "Maximum bytes to return. Default 65536, maximum 1048576.", "minimum": 1, "maximum": 1_048_576],
                ],
                "required": ["host", "path"],
                "additionalProperties": false,
            ]),
        AgentToolDefinition(
            name: AgentToolName.writeFile.rawValue,
            description: "Writes (or appends to) a file on a host with the given text. Overwrites existing files unless append is true. This changes the host, so the user is asked unless the host's allowlist permits it; read-only hosts refuse it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "host": hostParameter,
                    "path": ["type": "string", "description": "Absolute path, or relative to the login user's home."],
                    "contents": ["type": "string", "description": "The full text to write."],
                    "append": ["type": "boolean", "description": "Append instead of replacing. Default false."],
                    "mode": ["type": "string", "description": "Optional octal permissions to set after writing, e.g. \"0644\" or \"0755\"."],
                    "reason": ["type": "string", "description": "One line explaining why, shown to the user."],
                ],
                "required": ["host", "path", "contents", "reason"],
                "additionalProperties": false,
            ]),
        AgentToolDefinition(
            name: AgentToolName.sftpTransfer.rawValue,
            description: "Copies one file between this Mac and a host: direction \"download\" copies remote_path to local_path on the Mac, \"upload\" copies local_path from the Mac to remote_path on the host. Downloads count as reads, uploads as changes to the host.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "host": hostParameter,
                    "direction": ["type": "string", "enum": ["download", "upload"]],
                    "remote_path": ["type": "string"],
                    "local_path": ["type": "string", "description": "A path on the Mac. ~ is expanded."],
                    "reason": ["type": "string", "description": "One line explaining why, shown to the user."],
                ],
                "required": ["host", "direction", "remote_path", "local_path", "reason"],
                "additionalProperties": false,
            ]),
        AgentToolDefinition(
            name: AgentToolName.readTerminalBuffer.rawValue,
            description: "Returns the most recent lines of the user's open terminal on a host (what the user currently sees, including scrollback), or an empty result when no terminal is open there. Nothing runs on the host.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "host": hostParameter,
                    "max_lines": ["type": "integer", "description": "Lines from the bottom to return. Default 200, maximum 2000.", "minimum": 1, "maximum": 2000],
                ],
                "required": ["host"],
                "additionalProperties": false,
            ]),
        AgentToolDefinition(
            name: AgentToolName.createDocument.rawValue,
            description: "Writes a file on this Mac for the user from Markdown you compose: a report, summary, runbook, inventory or table. Formats: pdf (paginated, with headings, lists, tables and code blocks), docx (Microsoft Word), html, md, txt and csv. The file is saved in Tepfasonic's documents folder and appears in the panel as a card the user can open, show in Finder or save elsewhere, so tell them it is ready and what it contains. Nothing runs on any host. Gather the facts with the other tools first, then call this once with the whole document in `content`: GitHub-flavoured Markdown with #, ## and ### headings, paragraphs, - bullets, 1. numbered items, **bold**, *italic*, `code`, ``` fenced code blocks, | tables |, > quotes and --- rules. For txt and csv the content is written exactly as given.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "file_name": ["type": "string", "description": "Name for the file, for example \"Disk usage report\". The extension is added from the format."],
                    "format": ["type": "string", "enum": ["pdf", "docx", "html", "md", "txt", "csv"], "description": "pdf unless the user asked for Word (docx) or another format."],
                    "title": ["type": "string", "description": "Title printed at the top of the document and in its metadata. Optional."],
                    "content": ["type": "string", "description": "The whole document in Markdown (or the exact text for txt and csv)."],
                ],
                "required": ["file_name", "format", "content"],
                "additionalProperties": false,
            ]),
    ]

    public static func definition(_ name: AgentToolName) -> AgentToolDefinition {
        all.first { $0.name == name.rawValue }!
    }
}
