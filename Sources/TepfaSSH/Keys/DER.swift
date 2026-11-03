import Foundation

/// Just enough ASN.1 DER to read PKCS#1, PKCS#8 and SEC1 private keys.
struct DERReader {
    enum Tag: UInt8 {
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case null = 0x05
        case objectIdentifier = 0x06
        case sequence = 0x30
    }

    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        offset = 0
    }

    var isAtEnd: Bool { offset >= bytes.count }

    private mutating func readLength() throws -> Int {
        guard offset < bytes.count else { throw SSHKeyError.invalidFormat("truncated DER") }
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, offset + count <= bytes.count else { throw SSHKeyError.invalidFormat("bad DER length") }
        var length = 0
        for _ in 0..<count {
            length = length << 8 | Int(bytes[offset])
            offset += 1
        }
        return length
    }

    /// Reads a TLV with the expected tag and returns its content bytes.
    mutating func read(_ tag: Tag) throws -> [UInt8] {
        guard offset < bytes.count else { throw SSHKeyError.invalidFormat("truncated DER") }
        guard bytes[offset] == tag.rawValue else {
            throw SSHKeyError.invalidFormat("unexpected DER tag 0x\(String(bytes[offset], radix: 16)), wanted \(tag)")
        }
        offset += 1
        let length = try readLength()
        guard offset + length <= bytes.count else { throw SSHKeyError.invalidFormat("truncated DER") }
        let content = Array(bytes[offset..<offset + length])
        offset += length
        return content
    }

    mutating func peekTag() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    /// Skips one element of any tag.
    mutating func skip() throws {
        guard offset < bytes.count else { throw SSHKeyError.invalidFormat("truncated DER") }
        offset += 1
        let length = try readLength()
        offset += length
    }

    mutating func readSequence() throws -> DERReader {
        DERReader(try read(.sequence))
    }

    /// Unsigned big-endian magnitude of an INTEGER, leading zero stripped.
    mutating func readUnsignedInteger() throws -> [UInt8] {
        var value = try read(.integer)[...]
        while value.count > 1, value.first == 0 { value = value.dropFirst() }
        return Array(value)
    }

    mutating func readObjectIdentifier() throws -> String {
        let content = try read(.objectIdentifier)
        guard let first = content.first else { throw SSHKeyError.invalidFormat("empty OID") }
        var parts = [String(first / 40), String(first % 40)]
        var value = 0
        for byte in content.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(String(value))
                value = 0
            }
        }
        return parts.joined(separator: ".")
    }
}

/// PEM armor helpers.
enum PEM {
    static func body(_ text: String, label: String) -> Data? {
        OpenSSHPrivateKeyParser.pemBody(text, begin: "-----BEGIN \(label)-----", end: "-----END \(label)-----")
    }

    static func encode(_ bytes: [UInt8], label: String, lineLength: Int = 70) -> String {
        let base64 = Data(bytes).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: lineLength, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }
}
