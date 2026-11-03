import CryptoKit
import Foundation

public extension UUID {
    /// A name-based UUID (version 5 layout over SHA-256) so hosts imported from
    /// the same external source keep the same identity across imports.
    static func stable(_ name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("tepfasonic:" + name).utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
