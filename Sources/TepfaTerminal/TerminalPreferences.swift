import Foundation

/// UserDefaults-backed terminal behaviour settings shared by the app and the terminal view.
public enum TerminalPreferences {
    public static let copyOnSelectKey = "terminal.copyOnSelect"
    public static let warnOnMultiLinePasteKey = "terminal.warnOnMultiLinePaste"
    public static let scrollbackKey = "terminal.scrollback"
    public static let fontNameKey = "terminal.fontName"
    public static let fontSizeKey = "terminal.fontSize"
    public static let shellIntegrationKey = "terminal.shellIntegration"
    public static let recordHistoryKey = "history.record"
    public static let suggestionsKey = "history.suggestions"

    public static var copyOnSelect: Bool {
        UserDefaults.standard.object(forKey: copyOnSelectKey) as? Bool ?? false
    }

    public static var warnOnMultiLinePaste: Bool {
        UserDefaults.standard.object(forKey: warnOnMultiLinePasteKey) as? Bool ?? true
    }

    public static var scrollback: Int {
        let value = UserDefaults.standard.integer(forKey: scrollbackKey)
        return value > 0 ? value : 100_000
    }

    public static var fontName: String? {
        UserDefaults.standard.string(forKey: fontNameKey)
    }

    public static var fontSize: Double {
        let value = UserDefaults.standard.double(forKey: fontSizeKey)
        return value > 0 ? value : 13
    }

    /// Define OSC 133 prompt hooks on bash/zsh hosts after connecting (per-host override in the host editor).
    public static var shellIntegration: Bool {
        UserDefaults.standard.object(forKey: shellIntegrationKey) as? Bool ?? true
    }

    /// Keep a history of commands run in every session.
    public static var recordHistory: Bool {
        UserDefaults.standard.object(forKey: recordHistoryKey) as? Bool ?? true
    }

    /// Show inline suggestions from history and snippets while typing.
    public static var suggestions: Bool {
        UserDefaults.standard.object(forKey: suggestionsKey) as? Bool ?? true
    }
}
