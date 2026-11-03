import Foundation
import SwiftData

/// Every SwiftData model, in one place, so the app and tests build the same container.
public enum TepfaSchema {
    public static let models: [any PersistentModel.Type] = [
        SSHHost.self,
        HostGroup.self,
        Identity.self,
        Snippet.self,
        SnippetFolder.self,
        CommandHistoryEntry.self,
        AgentConversation.self,
        AgentAuditEntry.self,
        PortForwardRule.self,
        SerialProfile.self,
        TerminalThemeRecord.self,
    ]
}
