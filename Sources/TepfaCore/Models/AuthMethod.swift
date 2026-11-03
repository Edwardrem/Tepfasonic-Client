import Foundation

/// How we authenticate to a host. Stored on `SSHHost` as its raw value so the
/// SwiftData schema stays a plain string.
public enum AuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case password
    case privateKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .password: "Ask for a password"
        case .privateKey: "Identity"
        }
    }
}
