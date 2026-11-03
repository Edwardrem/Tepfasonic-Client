import Foundation
import SwiftData

/// A user-made or imported terminal colour scheme. Bundled schemes are not
/// stored; they ship in `TerminalTheme.bundled`.
@Model
public final class TerminalThemeRecord {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    /// The `TerminalTheme` as JSON.
    public var schemeJSON: Data
    public var createdAt: Date
    public var updatedAt: Date
    /// Where the scheme came from (`iterm2`, `windows-terminal`, `vscode`, `alacritty`, `ghostty`, `gallery`, `editor`).
    public var source: String

    public init(uuid: UUID = UUID(), name: String, schemeJSON: Data, source: String = "editor") {
        self.uuid = uuid
        self.name = name
        self.schemeJSON = schemeJSON
        self.createdAt = .now
        self.updatedAt = .now
        self.source = source
    }

    /// The id hosts and groups store in `themeID`.
    public var themeID: String { uuid.uuidString }
}
