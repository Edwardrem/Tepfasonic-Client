import Foundation

/// An HTTP CONNECT or SOCKS5 proxy the TCP connection to a host goes through.
public struct ProxySettings: Sendable, Hashable, Codable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case http
        case socks5

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .http: "HTTP CONNECT"
            case .socks5: "SOCKS5"
            }
        }
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var username: String?
    /// Kept in memory only for the connection attempt; never persisted here.
    public var password: String?

    public init(kind: Kind, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var displayTarget: String { "\(kind.displayName) \(host):\(port)" }

    private enum CodingKeys: String, CodingKey { case kind, host, port, username }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(username, forKey: .username)
    }
}

public enum ProxyError: Error, LocalizedError, Sendable, Equatable {
    case httpRefused(Int, String)
    case socksRefused(UInt8)
    case authenticationRequired
    case authenticationFailed
    case malformedReply

    public var errorDescription: String? {
        switch self {
        case .httpRefused(let status, let reason): "The HTTP proxy refused the tunnel: \(status) \(reason)".trimmingCharacters(in: .whitespaces)
        case .socksRefused(let code): "The SOCKS5 proxy refused the connection (\(SOCKS5.replyDescription(code)))."
        case .authenticationRequired: "The proxy requires a username and password."
        case .authenticationFailed: "The proxy rejected the username or password."
        case .malformedReply: "The proxy sent a reply that could not be understood."
        }
    }
}
