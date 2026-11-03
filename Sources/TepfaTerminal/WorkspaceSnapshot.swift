import Foundation
import TepfaCore

/// Everything needed to restore open tabs on relaunch.
public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public struct Tab: Codable, Sendable, Equatable {
        public var id: UUID
        public var tree: PaneNode
        public var focusedLeafID: UUID
        public var customTitle: String?

        public init(id: UUID, tree: PaneNode, focusedLeafID: UUID, customTitle: String? = nil) {
            self.id = id
            self.tree = tree
            self.focusedLeafID = focusedLeafID
            self.customTitle = customTitle
        }
    }

    public var version = 1
    public var tabs: [Tab]
    public var selectedTabID: UUID?
    /// Session ID → saved host UUID.
    public var sessionHosts: [UUID: UUID]
    /// Session ID → unsaved (quick-connect) host, restored verbatim.
    public var transientHosts: [UUID: HostDescriptor]

    public init(tabs: [Tab], selectedTabID: UUID?, sessionHosts: [UUID: UUID], transientHosts: [UUID: HostDescriptor]) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.sessionHosts = sessionHosts
        self.transientHosts = transientHosts
    }

    public static var defaultURL: URL {
        AppPaths.applicationSupport.appending(path: "workspace.json")
    }

    public static func load(from url: URL = defaultURL) -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
