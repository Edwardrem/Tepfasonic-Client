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
    public static let cursorStyleKey = "terminal.cursorStyle"
    public static let cursorBlinkKey = "terminal.cursorBlink"
    public static let antialiasKey = "terminal.antialias"
    public static let minimumContrastKey = "terminal.minimumContrast"
    public static let backgroundOpacityKey = "terminal.backgroundOpacity"
    public static let backgroundBlurKey = "terminal.backgroundBlur"
    public static let ligaturesKey = "terminal.ligatures"
    public static let lineHeightKey = "terminal.lineHeight"
    public static let letterSpacingKey = "terminal.letterSpacing"
    public static let boldFontKey = "terminal.boldFont"
    public static let italicFontKey = "terminal.italicFont"
    public static let linkModifierKey = "terminal.linkModifier"
    public static let badgeEnabledKey = "terminal.badge.enabled"
    public static let badgePositionKey = "terminal.badge.position"
    public static let badgeColorKey = "terminal.badge.color"
    public static let badgeShowsUserKey = "terminal.badge.user"
    public static let badgeShowsUptimeKey = "terminal.badge.uptime"
    public static let defaultFontName = "JetBrains Mono"

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

    /// The chosen font family; nil means the bundled default (JetBrains Mono, else the system monospace font).
    public static var fontName: String? {
        UserDefaults.standard.string(forKey: fontNameKey)
    }

    /// `block`, `bar` or `underline`.
    public static var cursorStyle: String {
        UserDefaults.standard.string(forKey: cursorStyleKey) ?? "block"
    }

    public static var cursorBlink: Bool {
        UserDefaults.standard.object(forKey: cursorBlinkKey) as? Bool ?? true
    }

    public static var antialias: Bool {
        UserDefaults.standard.object(forKey: antialiasKey) as? Bool ?? true
    }

    /// WCAG contrast ratio forced between text and its background (1 = off).
    public static var minimumContrast: Double {
        let value = UserDefaults.standard.double(forKey: minimumContrastKey)
        return value >= 1 ? value : 1
    }

    public static var backgroundOpacity: Double {
        guard UserDefaults.standard.object(forKey: backgroundOpacityKey) != nil else { return 1 }
        return min(max(UserDefaults.standard.double(forKey: backgroundOpacityKey), 0.2), 1)
    }

    public static var backgroundBlur: Bool {
        UserDefaults.standard.object(forKey: backgroundBlurKey) as? Bool ?? true
    }

    public static var ligatures: Bool {
        UserDefaults.standard.object(forKey: ligaturesKey) as? Bool ?? true
    }

    /// Multiplier on the font's natural line height (stored for fonts that support it; 1 = natural).
    public static var lineHeight: Double {
        let value = UserDefaults.standard.double(forKey: lineHeightKey)
        return value > 0 ? value : 1
    }

    public static var letterSpacing: Double {
        UserDefaults.standard.double(forKey: letterSpacingKey)
    }

    public static var boldFont: Bool {
        UserDefaults.standard.object(forKey: boldFontKey) as? Bool ?? true
    }

    public static var italicFont: Bool {
        UserDefaults.standard.object(forKey: italicFontKey) as? Bool ?? true
    }

    /// Whether links need ⌘ to open on click.
    public static var linkNeedsModifier: Bool {
        UserDefaults.standard.object(forKey: linkModifierKey) as? Bool ?? true
    }

    public static var badgeEnabled: Bool {
        UserDefaults.standard.bool(forKey: badgeEnabledKey)
    }

    /// `topRight`, `topLeft`, `bottomRight`, `bottomLeft`.
    public static var badgePosition: String {
        UserDefaults.standard.string(forKey: badgePositionKey) ?? "topRight"
    }

    public static var badgeColor: String? {
        UserDefaults.standard.string(forKey: badgeColorKey)
    }

    public static var badgeShowsUser: Bool {
        UserDefaults.standard.object(forKey: badgeShowsUserKey) as? Bool ?? true
    }

    public static var badgeShowsUptime: Bool {
        UserDefaults.standard.object(forKey: badgeShowsUptimeKey) as? Bool ?? true
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
