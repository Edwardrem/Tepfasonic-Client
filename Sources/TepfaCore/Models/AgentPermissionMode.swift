import Foundation

/// What the Claude agent (and MCP clients) may run on a host without asking.
public enum AgentPermissionMode: String, CaseIterable, Codable, Sendable {
    /// Only commands on the built-in read-only list run; everything else is refused.
    case readOnly = "read-only"
    /// Every command is shown in an approval sheet before it runs.
    case ask
    /// Commands matching the host's patterns run automatically; everything else asks.
    case allowlist

    public var displayName: String {
        switch self {
        case .readOnly: "Read-only"
        case .ask: "Ask every time"
        case .allowlist: "Allowlist"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly: "Only inspection commands such as ls, cat, df and systemctl status may run. Anything that changes the host is refused."
        case .ask: "Each command is shown with the host and Claude's reason, and runs only after you approve it."
        case .allowlist: "Commands matching your patterns run on their own. Everything else asks first. Destructive commands always ask."
        }
    }
}
