import CryptoKit
import Foundation

/// OpenSSH-compatible `SHA256:` fingerprints for host and user keys.
public enum HostKeyFingerprint {
    /// Fingerprint of an OpenSSH public key line (`type base64 [comment]`).
    /// Matches `ssh-keygen -lf`.
    public static func sha256(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return sha256(keyBlob: blob)
    }

    /// Fingerprint of a raw SSH wire-format public key blob.
    public static func sha256(keyBlob: Data) -> String {
        let digest = SHA256.hash(data: keyBlob)
        let encoded = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + encoded
    }

    /// `type base64` with any trailing comment removed, or nil when the line is malformed.
    public static func normalize(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]) \(parts[1])"
    }
}
