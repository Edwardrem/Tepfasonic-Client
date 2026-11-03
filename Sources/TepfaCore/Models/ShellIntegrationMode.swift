import Foundation

/// Whether Tepfasonic defines OSC 133 prompt hooks in the remote shell after connecting.
public enum ShellIntegrationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Follow the global setting.
    case automatic
    case enabled
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Use the global setting"
        case .enabled: "Always"
        case .disabled: "Never"
        }
    }
}
