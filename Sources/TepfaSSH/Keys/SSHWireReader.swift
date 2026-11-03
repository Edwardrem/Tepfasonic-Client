import Foundation

/// Reads the length-prefixed fields used by SSH wire formats (RFC 4251).
struct SSHWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func expectPrefix(_ prefix: [UInt8], description: String) throws {
        guard remaining >= prefix.count, Array(bytes[offset..<offset + prefix.count]) == prefix else {
            throw SSHKeyError.invalidFormat("missing \(description)")
        }
        offset += prefix.count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHKeyError.invalidFormat("truncated data") }
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw SSHKeyError.invalidFormat("truncated data") }
        let out = Array(bytes[offset..<offset + count])
        offset += count
        return out
    }

    /// `string` / `mpint`: uint32 length followed by that many bytes.
    mutating func readString() throws -> [UInt8] {
        let length = try readUInt32()
        return try readBytes(Int(length))
    }

    mutating func readUTF8String() throws -> String {
        guard let string = String(bytes: try readString(), encoding: .utf8) else {
            throw SSHKeyError.invalidFormat("invalid UTF-8 string")
        }
        return string
    }
}
