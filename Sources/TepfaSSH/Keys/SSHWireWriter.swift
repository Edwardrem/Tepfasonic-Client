import Foundation

/// Writes the length-prefixed fields used by SSH wire formats (RFC 4251).
struct SSHWireWriter {
    private(set) var bytes: [UInt8] = []

    init() {}

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func writeBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func writeString(_ raw: [UInt8]) {
        writeUInt32(UInt32(raw.count))
        bytes.append(contentsOf: raw)
    }

    mutating func writeString(_ text: String) {
        writeString(Array(text.utf8))
    }

    /// Writes a positive big-endian integer as an `mpint`: leading zeros stripped,
    /// a zero byte prepended when the top bit is set.
    mutating func writeMPInt(_ magnitude: [UInt8]) {
        var value = magnitude[...]
        while value.first == 0 { value = value.dropFirst() }
        if let first = value.first, first & 0x80 != 0 {
            writeUInt32(UInt32(value.count + 1))
            bytes.append(0)
            bytes.append(contentsOf: value)
        } else {
            writeString(Array(value))
        }
    }
}
