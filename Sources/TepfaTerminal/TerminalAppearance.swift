import AppKit
import CoreText
import Foundation
import SwiftTerm
import TepfaCore

/// Everything the terminal view needs to look right for one session:
/// the resolved colour scheme, font and rendering options.
public struct TerminalAppearance: Sendable, Equatable {
    public var theme: TerminalTheme
    public var fontName: String?
    public var fontSize: Double
    /// `block`, `bar` or `underline`.
    public var cursorStyle: String
    public var cursorBlink: Bool
    public var antialias: Bool
    public var minimumContrast: Double
    public var backgroundOpacity: Double
    public var ligatures: Bool
    public var lineHeight: Double
    public var boldFont: Bool
    public var italicFont: Bool
    public var linkNeedsModifier: Bool

    public init(
        theme: TerminalTheme,
        fontName: String? = nil,
        fontSize: Double = 13,
        cursorStyle: String = "block",
        cursorBlink: Bool = true,
        antialias: Bool = true,
        minimumContrast: Double = 1,
        backgroundOpacity: Double = 1,
        ligatures: Bool = true,
        lineHeight: Double = 1,
        boldFont: Bool = true,
        italicFont: Bool = true,
        linkNeedsModifier: Bool = true
    ) {
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.antialias = antialias
        self.minimumContrast = minimumContrast
        self.backgroundOpacity = backgroundOpacity
        self.ligatures = ligatures
        self.lineHeight = lineHeight
        self.boldFont = boldFont
        self.italicFont = italicFont
        self.linkNeedsModifier = linkNeedsModifier
    }

    /// The global settings with the default dark scheme.
    public static func global(theme: TerminalTheme) -> TerminalAppearance {
        TerminalAppearance(
            theme: theme,
            fontName: TerminalPreferences.fontName,
            fontSize: TerminalPreferences.fontSize,
            cursorStyle: TerminalPreferences.cursorStyle,
            cursorBlink: TerminalPreferences.cursorBlink,
            antialias: TerminalPreferences.antialias,
            minimumContrast: TerminalPreferences.minimumContrast,
            backgroundOpacity: TerminalPreferences.backgroundOpacity,
            ligatures: TerminalPreferences.ligatures,
            lineHeight: TerminalPreferences.lineHeight,
            boldFont: TerminalPreferences.boldFont,
            italicFont: TerminalPreferences.italicFont,
            linkNeedsModifier: TerminalPreferences.linkNeedsModifier)
    }

    // MARK: AppKit / SwiftTerm conversions

    public static func nsColor(_ hex: String) -> NSColor {
        guard let (r, g, b) = TerminalTheme.rgb(hex) else { return .black }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    public static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        guard let (r, g, b) = TerminalTheme.rgb(hex) else { return SwiftTerm.Color(red: 0, green: 0, blue: 0) }
        return SwiftTerm.Color(red8: UInt16((r * 255).rounded()), green8: UInt16((g * 255).rounded()), blue8: UInt16((b * 255).rounded()))
    }

    public var swiftTermCursorStyle: CursorStyle {
        switch (cursorStyle, cursorBlink) {
        case ("bar", true): .blinkBar
        case ("bar", false): .steadyBar
        case ("underline", true): .blinkUnderline
        case ("underline", false): .steadyUnderline
        case (_, true): .blinkBlock
        default: .steadyBlock
        }
    }

    /// The font, with ligatures turned off through a font feature when asked.
    public func font() -> NSFont {
        let size = CGFloat(fontSize)
        var base: NSFont
        if let fontName, let named = NSFont(name: fontName, size: size) {
            base = named
        } else if let bundled = NSFont(name: TerminalPreferences.defaultFontName, size: size) {
            base = bundled
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if !ligatures {
            let descriptor = base.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType, NSFontDescriptor.FeatureKey.selectorIdentifier: kCommonLigaturesOffSelector],
                    [NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType, NSFontDescriptor.FeatureKey.selectorIdentifier: kContextualLigaturesOffSelector],
                ],
            ])
            base = NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }
}
