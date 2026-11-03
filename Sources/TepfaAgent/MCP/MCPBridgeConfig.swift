import Foundation
import TepfaCore

/// How the stdio bridge (and other local clients) find the app's MCP server:
/// a small JSON file in Application Support, readable only by the user.
public struct MCPBridgeConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var port: Int
    public var token: String

    public static let defaultPort = 7317

    public init(port: Int, token: String, version: Int = 1) {
        self.version = version
        self.port = port
        self.token = token
    }

    public static var url: URL { AppPaths.applicationSupport.appending(path: "mcp.json") }

    public static func load() -> MCPBridgeConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPBridgeConfig.self, from: data)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    public static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// 32 random bytes, base64url.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public var httpURL: String { "http://127.0.0.1:\(port)/mcp" }
}
