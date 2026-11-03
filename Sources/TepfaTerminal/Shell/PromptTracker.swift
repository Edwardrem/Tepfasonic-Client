import Foundation

/// Where the remote shell is in its prompt/command cycle, from OSC 133 markers.
public enum PromptPhase: Equatable, Sendable {
    /// No shell integration seen yet.
    case unknown
    /// Prompt printed; the user may be typing.
    case prompt
    /// A command is running.
    case running
}

/// Parsed OSC 133 payload.
enum SemanticPromptAction: Equatable {
    case promptStart      // A, N
    case inputStart       // B, I
    case commandStart     // C
    case commandEnd(Int?) // D[;status]

    init?(payload: [UInt8]) {
        guard let text = String(bytes: payload, encoding: .utf8), let first = text.first else { return nil }
        switch first {
        case "A", "N": self = .promptStart
        case "B", "I": self = .inputStart
        case "C": self = .commandStart
        case "D":
            let fields = text.split(separator: ";", omittingEmptySubsequences: false)
            self = .commandEnd(fields.count > 1 ? Int(fields[1].trimmingCharacters(in: .whitespaces)) : nil)
        default: return nil
        }
    }
}

/// Parsed OSC 7 payload: `file://host/path`.
enum WorkingDirectoryReport {
    static func path(from payload: [UInt8]) -> String? {
        guard let text = String(bytes: payload, encoding: .utf8),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "file" else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path.removingPercentEncoding ?? path
    }
}
