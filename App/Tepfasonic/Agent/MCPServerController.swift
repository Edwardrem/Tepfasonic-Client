import Foundation
import Observation
import TepfaAgent
import TepfaCore

/// Runs the MCP server on localhost when enabled and keeps `mcp.json` (port
/// and token) in sync for the stdio bridge.
@MainActor
@Observable
final class MCPServerController {
    static let enabledKey = "mcp.enabled"
    static let portKey = "mcp.port"

    private let toolHost: any AgentToolHost
    private var server: MCPServer?

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            Task { await apply() }
        }
    }
    var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: Self.portKey)
            if isEnabled { Task { await restart() } }
        }
    }
    private(set) var token: String
    /// The port actually bound, once the server runs.
    private(set) var boundPort: Int?
    private(set) var lastError: String?
    var isRunning: Bool { boundPort != nil }

    init(toolHost: any AgentToolHost) {
        self.toolHost = toolHost
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = storedPort == 0 ? MCPBridgeConfig.defaultPort : storedPort
        token = MCPBridgeConfig.load()?.token ?? MCPBridgeConfig.makeToken()
    }

    /// Starts or stops to match `isEnabled`.
    func apply() async {
        if isEnabled {
            if server == nil { await start() }
        } else {
            await stop()
        }
    }

    private func start() async {
        lastError = nil
        let server = MCPServer(toolHost: toolHost, token: token, serverVersion: UpdateManager.currentShortVersion)
        do {
            let bound = try await server.start(port: port)
            self.server = server
            boundPort = bound
            try MCPBridgeConfig(port: bound, token: token).save()
        } catch {
            lastError = "Could not start the MCP server on port \(port): \(error.localizedDescription)"
            await server.stop()
        }
    }

    func stop() async {
        if let server {
            self.server = nil
            boundPort = nil
            await server.stop()
        }
        MCPBridgeConfig.remove()
    }

    func restart() async {
        await stop()
        await start()
    }

    func regenerateToken() {
        token = MCPBridgeConfig.makeToken()
        Task { if isEnabled { await restart() } }
    }

    // MARK: Client configuration

    /// The stdio bridge inside the app bundle.
    var bridgePath: String {
        (Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL)
            .appending(path: "tepfasonic-mcp").path
    }

    var httpURL: String { "http://127.0.0.1:\(boundPort ?? port)/mcp" }

    /// For ~/Library/Application Support/Claude/claude_desktop_config.json.
    var claudeDesktopSnippet: String {
        """
        {
          "mcpServers": {
            "tepfasonic": {
              "command": \(jsonString(bridgePath))
            }
          }
        }
        """
    }

    /// For Claude Code (stdio through the bridge).
    var claudeCodeCommand: String {
        "claude mcp add tepfasonic -- \(shellQuote(bridgePath))"
    }

    /// For clients that speak streamable HTTP directly.
    var claudeCodeHTTPCommand: String {
        "claude mcp add --transport http tepfasonic \(httpURL) --header \"Authorization: Bearer \(token)\""
    }

    private func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
