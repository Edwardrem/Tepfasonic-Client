import Foundation

/// SFTP version 3 wire format (draft-ietf-secsh-filexfer-02), the version
/// every OpenSSH server speaks. Pure data and codecs; the client is in
/// `SFTPClient`.
public enum SFTP {
    public static let protocolVersion: UInt32 = 3

    enum PacketType: UInt8 {
        case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6, lstat = 7, fstat = 8, setstat = 9, fsetstat = 10
        case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18, readlink = 19, symlink = 20
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105, extended = 200, extendedReply = 201
    }

    /// Status codes in SSH_FXP_STATUS.
    public enum StatusCode: UInt32, Sendable {
        case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4, badMessage = 5, noConnection = 6, connectionLost = 7, opUnsupported = 8

        public var description: String {
            switch self {
            case .ok: "OK"
            case .eof: "end of file"
            case .noSuchFile: "no such file"
            case .permissionDenied: "permission denied"
            case .failure: "failure"
            case .badMessage: "bad message"
            case .noConnection: "no connection"
            case .connectionLost: "connection lost"
            case .opUnsupported: "operation unsupported"
            }
        }
    }

    /// Flags for SSH_FXP_OPEN.
    public struct OpenFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let read = OpenFlags(rawValue: 0x01)
        public static let write = OpenFlags(rawValue: 0x02)
        public static let append = OpenFlags(rawValue: 0x04)
        public static let create = OpenFlags(rawValue: 0x08)
        public static let truncate = OpenFlags(rawValue: 0x10)
        public static let exclusive = OpenFlags(rawValue: 0x20)
    }

    struct AttributeFlags: OptionSet {
        let rawValue: UInt32
        static let size = AttributeFlags(rawValue: 0x01)
        static let uidgid = AttributeFlags(rawValue: 0x02)
        static let permissions = AttributeFlags(rawValue: 0x04)
        static let acmodtime = AttributeFlags(rawValue: 0x08)
        static let extended = AttributeFlags(rawValue: 0x8000_0000)
    }

    public enum FileKind: Sendable, Equatable {
        case regular, directory, symlink, other
    }

    /// File attributes as the server reports them.
    public struct Attributes: Sendable, Equatable {
        public var size: UInt64?
        public var uid: UInt32?
        public var gid: UInt32?
        public var permissions: UInt32?
        public var accessTime: Date?
        public var modificationTime: Date?
        public var extended: [String: String] = [:]

        public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil, accessTime: Date? = nil, modificationTime: Date? = nil) {
            self.size = size
            self.uid = uid
            self.gid = gid
            self.permissions = permissions
            self.accessTime = accessTime
            self.modificationTime = modificationTime
        }

        public var kind: FileKind {
            guard let permissions else { return .other }
            switch permissions & 0o170000 {
            case 0o100000: return .regular
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .other
            }
        }

        public var isDirectory: Bool { kind == .directory }
        public var isSymlink: Bool { kind == .symlink }

        /// The permission bits only (`0o644`).
        public var mode: UInt32? { permissions.map { $0 & 0o7777 } }

        /// `-rw-r--r--`
        public var modeString: String {
            guard let permissions else { return "?????????" }
            var out = ""
            switch kind {
            case .directory: out += "d"
            case .symlink: out += "l"
            case .regular: out += "-"
            case .other: out += "?"
            }
            let bits: [(UInt32, String)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
            for (bit, letter) in bits { out += permissions & bit != 0 ? letter : "-" }
            return out
        }

        func encode(into writer: inout SFTPWriter) {
            var flags: AttributeFlags = []
            if size != nil { flags.insert(.size) }
            if uid != nil, gid != nil { flags.insert(.uidgid) }
            if permissions != nil { flags.insert(.permissions) }
            if accessTime != nil, modificationTime != nil { flags.insert(.acmodtime) }
            writer.writeUInt32(flags.rawValue)
            if let size { writer.writeUInt64(size) }
            if let uid, let gid { writer.writeUInt32(uid); writer.writeUInt32(gid) }
            if let permissions { writer.writeUInt32(permissions) }
            if let accessTime, let modificationTime {
                writer.writeUInt32(UInt32(clamping: Int64(accessTime.timeIntervalSince1970)))
                writer.writeUInt32(UInt32(clamping: Int64(modificationTime.timeIntervalSince1970)))
            }
        }

        static func decode(from reader: inout SFTPReader) throws -> Attributes {
            var attributes = Attributes()
            let flags = AttributeFlags(rawValue: try reader.readUInt32())
            if flags.contains(.size) { attributes.size = try reader.readUInt64() }
            if flags.contains(.uidgid) {
                attributes.uid = try reader.readUInt32()
                attributes.gid = try reader.readUInt32()
            }
            if flags.contains(.permissions) { attributes.permissions = try reader.readUInt32() }
            if flags.contains(.acmodtime) {
                attributes.accessTime = Date(timeIntervalSince1970: TimeInterval(try reader.readUInt32()))
                attributes.modificationTime = Date(timeIntervalSince1970: TimeInterval(try reader.readUInt32()))
            }
            if flags.contains(.extended) {
                let count = try reader.readUInt32()
                for _ in 0..<count {
                    let type = try reader.readString()
                    let data = try reader.readString()
                    attributes.extended[type] = data
                }
            }
            return attributes
        }
    }

    /// One entry of a directory listing.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var name: String
        /// The `ls -l` style line the server sent, when it did.
        public var longName: String
        public var attributes: Attributes

        public var id: String { name }

        public init(name: String, longName: String = "", attributes: Attributes) {
            self.name = name
            self.longName = longName
            self.attributes = attributes
        }

        /// Owner and group from the long name (`-rw-r--r--  1 alice staff …`), when present.
        public var ownerAndGroup: (String, String)? {
            let parts = longName.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { return nil }
            return (String(parts[2]), String(parts[3]))
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case status(StatusCode, String, path: String?)
        case protocolError(String)
        case unsupportedVersion(UInt32)
        case closed

        public var errorDescription: String? {
            switch self {
            case .status(let code, let message, let path):
                let detail = message.isEmpty ? code.description : message
                return path.map { "\(detail) (\($0))" } ?? detail
            case .protocolError(let detail): return "SFTP protocol error: \(detail)"
            case .unsupportedVersion(let version): return "The server speaks SFTP version \(version); Tepfasonic needs version 3."
            case .closed: return "The SFTP session is closed."
            }
        }

        public var isNoSuchFile: Bool {
            if case .status(.noSuchFile, _, _) = self { return true }
            return false
        }
    }

    // MARK: Path helpers

    /// Joins remote paths with `/`, normalising `.` and `..` segments.
    public static func join(_ base: String, _ component: String) -> String {
        if component.hasPrefix("/") { return normalize(component) }
        return normalize(base.hasSuffix("/") ? base + component : base + "/" + component)
    }

    public static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        var parts = normalized.split(separator: "/", omittingEmptySubsequences: true)
        parts.removeLast()
        return "/" + parts.joined(separator: "/")
    }

    public static func baseName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
}

/// Big-endian reader for SFTP packets.
struct SFTPReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTP.Error.protocolError("packet truncated") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTP.Error.protocolError("packet truncated") }
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(bytes[offset + index]) }
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw SFTP.Error.protocolError("packet truncated") }
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(bytes[offset + index]) }
        offset += 8
        return value
    }

    mutating func readBytes() throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard remaining >= length else { throw SFTP.Error.protocolError("string truncated") }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    mutating func readString() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }
}

/// Big-endian writer for SFTP packets.
struct SFTPWriter {
    private(set) var bytes: [UInt8] = []

    init() {}

    mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32(value >> 32))
        writeUInt32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func writeBytes(_ raw: [UInt8]) {
        writeUInt32(UInt32(raw.count))
        bytes.append(contentsOf: raw)
    }

    mutating func writeString(_ text: String) {
        writeBytes(Array(text.utf8))
    }

    /// The packet with its length prefix.
    func framed() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        let length = UInt32(bytes.count)
        out.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        out.append(contentsOf: bytes)
        return out
    }
}

/// Splits a byte stream into SFTP packets (uint32 length + body).
public struct SFTPFramer: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds bytes and returns every complete packet body (type byte first).
    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var packets: [[UInt8]] = []
        var start = 0
        while buffer.count - start >= 4 {
            let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard buffer.count - start - 4 >= length else { break }
            packets.append(Array(buffer[(start + 4)..<(start + 4 + length)]))
            start += 4 + length
        }
        if start > 0 { buffer.removeFirst(start) }
        return packets
    }
}
