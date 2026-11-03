import Foundation

/// SOCKS5 wire format (RFC 1928 / 1929), shared by the proxy client and the
/// dynamic-forwarding server. Pure functions so they can be tested.
public enum SOCKS5 {
    public enum Address: Sendable, Equatable {
        case ipv4([UInt8])
        case ipv6([UInt8])
        case domain(String)

        public var hostString: String {
            switch self {
            case .ipv4(let bytes): bytes.map(String.init).joined(separator: ".")
            case .ipv6(let bytes):
                stride(from: 0, to: 16, by: 2).map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }.joined(separator: ":")
            case .domain(let name): name
            }
        }
    }

    /// A CONNECT request from a SOCKS client (what the dynamic forwarder receives).
    public struct Request: Sendable, Equatable {
        public var command: UInt8
        public var address: Address
        public var port: Int
        /// Bytes consumed.
        public var length: Int
    }

    public struct Reply: Sendable, Equatable {
        public var code: UInt8
        public var length: Int
    }

    public enum ParseError: Error, Equatable {
        case badVersion(UInt8)
        case badAddressType(UInt8)
    }

    // MARK: Client side

    public static func clientGreeting(offersPassword: Bool) -> [UInt8] {
        offersPassword ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
    }

    public static func passwordAuthentication(username: String, password: String) -> [UInt8] {
        let user = Array(username.utf8.prefix(255))
        let pass = Array(password.utf8.prefix(255))
        return [0x01, UInt8(user.count)] + user + [UInt8(pass.count)] + pass
    }

    public static func connectRequest(host: String, port: Int) -> [UInt8] {
        var out: [UInt8] = [0x05, 0x01, 0x00]
        out += encodeAddress(host)
        out += [UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)]
        return out
    }

    static func encodeAddress(_ host: String) -> [UInt8] {
        if let v4 = ipv4Bytes(host) { return [0x01] + v4 }
        if let v6 = ipv6Bytes(host) { return [0x04] + v6 }
        let name = Array(host.utf8.prefix(255))
        return [0x03, UInt8(name.count)] + name
    }

    /// Parses the proxy's reply to CONNECT; nil when more bytes are needed.
    public static func parseReply<C: Collection>(_ bytes: C) throws -> Reply? where C.Element == UInt8, C.Index == Int {
        guard bytes.count >= 4 else { return nil }
        let start = bytes.startIndex
        guard bytes[start] == 5 else { throw ParseError.badVersion(bytes[start]) }
        let code = bytes[start + 1]
        guard let (_, consumed) = try parseAddress(bytes, at: start + 3) else { return nil }
        let total = 3 + consumed + 2
        guard bytes.count >= total else { return nil }
        return Reply(code: code, length: total)
    }

    // MARK: Server side

    /// Parses the client's method greeting; returns the offered methods, or nil when incomplete.
    public static func parseGreeting<C: Collection>(_ bytes: C) throws -> (methods: [UInt8], length: Int)? where C.Element == UInt8, C.Index == Int {
        guard bytes.count >= 2 else { return nil }
        let start = bytes.startIndex
        guard bytes[start] == 5 else { throw ParseError.badVersion(bytes[start]) }
        let count = Int(bytes[start + 1])
        guard bytes.count >= 2 + count else { return nil }
        return (Array(bytes[(start + 2)..<(start + 2 + count)]), 2 + count)
    }

    /// Parses a client request (`VER CMD RSV ATYP ADDR PORT`); nil when incomplete.
    public static func parseRequest<C: Collection>(_ bytes: C) throws -> Request? where C.Element == UInt8, C.Index == Int {
        guard bytes.count >= 4 else { return nil }
        let start = bytes.startIndex
        guard bytes[start] == 5 else { throw ParseError.badVersion(bytes[start]) }
        let command = bytes[start + 1]
        guard let (address, consumed) = try parseAddress(bytes, at: start + 3) else { return nil }
        let portIndex = start + 3 + consumed
        guard bytes.count >= 3 + consumed + 2 else { return nil }
        let port = Int(bytes[portIndex]) << 8 | Int(bytes[portIndex + 1])
        return Request(command: command, address: address, port: port, length: 3 + consumed + 2)
    }

    public static func reply(code: UInt8, boundHost: String = "0.0.0.0", boundPort: Int = 0) -> [UInt8] {
        [0x05, code, 0x00] + encodeAddress(boundHost) + [UInt8((boundPort >> 8) & 0xFF), UInt8(boundPort & 0xFF)]
    }

    public static let replyGeneralFailure: UInt8 = 0x01
    public static let replyNotAllowed: UInt8 = 0x02
    public static let replyNetworkUnreachable: UInt8 = 0x03
    public static let replyHostUnreachable: UInt8 = 0x04
    public static let replyConnectionRefused: UInt8 = 0x05
    public static let replyCommandNotSupported: UInt8 = 0x07
    public static let replyAddressNotSupported: UInt8 = 0x08

    public static func replyDescription(_ code: UInt8) -> String {
        switch code {
        case 0: "succeeded"
        case 1: "general failure"
        case 2: "connection not allowed by ruleset"
        case 3: "network unreachable"
        case 4: "host unreachable"
        case 5: "connection refused"
        case 6: "TTL expired"
        case 7: "command not supported"
        case 8: "address type not supported"
        default: "code \(code)"
        }
    }

    // MARK: Addresses

    /// Address starting at `index` (the ATYP byte). Returns the address and bytes consumed, or nil when incomplete.
    static func parseAddress<C: Collection>(_ bytes: C, at index: Int) throws -> (Address, Int)? where C.Element == UInt8, C.Index == Int {
        guard bytes.endIndex > index else { return nil }
        switch bytes[index] {
        case 0x01:
            guard bytes.endIndex >= index + 5 else { return nil }
            return (.ipv4(Array(bytes[(index + 1)..<(index + 5)])), 5)
        case 0x04:
            guard bytes.endIndex >= index + 17 else { return nil }
            return (.ipv6(Array(bytes[(index + 1)..<(index + 17)])), 17)
        case 0x03:
            guard bytes.endIndex > index + 1 else { return nil }
            let length = Int(bytes[index + 1])
            guard bytes.endIndex >= index + 2 + length else { return nil }
            return (.domain(String(decoding: bytes[(index + 2)..<(index + 2 + length)], as: UTF8.self)), 2 + length)
        case let other:
            throw ParseError.badAddressType(other)
        }
    }

    static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            out.append(value)
        }
        return out
    }

    static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var text = host
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        guard text.contains(":") else { return nil }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}
