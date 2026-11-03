import Foundation
import SwiftData

/// A folder in the snippet list. Flat on purpose: nesting rarely earns its UI.
@Model
public final class SnippetFolder {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Snippet.folder)
    public var snippets: [Snippet]

    public init(uuid: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.uuid = uuid
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.snippets = []
    }
}

/// A saved command. `{{name}}` and `{{name:default}}` placeholders are asked
/// for when the snippet runs; see `SnippetVariables`.
@Model
public final class Snippet {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    public var command: String
    public var tags: [String]
    public var notes: String
    public var sortOrder: Int
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var folder: SnippetFolder?

    @Relationship(deleteRule: .nullify, inverse: \SSHHost.defaultSnippet)
    public var hostsRunningOnConnect: [SSHHost]

    public init(
        uuid: UUID = UUID(),
        name: String,
        command: String,
        tags: [String] = [],
        notes: String = "",
        sortOrder: Int = 0,
        folder: SnippetFolder? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.command = command
        self.tags = tags
        self.notes = notes
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.lastUsedAt = nil
        self.useCount = 0
        self.folder = folder
        self.hostsRunningOnConnect = []
    }

    public var variables: [SnippetVariables.Variable] {
        SnippetVariables.variables(in: command)
    }

    public func noteUsed() {
        useCount += 1
        lastUsedAt = .now
    }
}
