import AppKit
import SwiftUI
import TepfaCore

/// The colours the app's own chrome is drawn with: sidebar, tab bar, status
/// bar, panel, cards, sheets and window backgrounds. Derived from the colour
/// scheme in use (so Solarized colours the whole app, not just the terminal),
/// or the standard macOS materials when that is turned off.
struct AppPalette {
    /// True when the colours come from the terminal scheme.
    let fromScheme: Bool
    let isDark: Bool
    /// Window and content background.
    let background: Color
    /// Sidebar, tab bar, status bar and composer area.
    let surface: AnyShapeStyle
    /// A solid version of `surface` for places that need a colour.
    let surfaceColor: Color
    /// Cards, pills, selected tabs, text fields.
    let raised: Color
    /// Body text in the chrome (the scheme's foreground, lifted to readable contrast).
    let text: Color
    let secondaryText: Color
    /// Nil follows the system accent.
    let accent: Color?
    /// Text drawn on top of `accent` (message bubbles).
    let onAccent: Color
    let separator: Color
    let selection: Color
    let backgroundNSColor: NSColor

    /// The standard look: materials and dynamic system colours.
    static let system = AppPalette(
        fromScheme: false,
        isDark: false,
        background: Color(nsColor: .windowBackgroundColor),
        surface: AnyShapeStyle(.bar),
        surfaceColor: Color(nsColor: .windowBackgroundColor),
        raised: Color(nsColor: .controlBackgroundColor),
        text: .primary,
        secondaryText: .secondary,
        accent: nil,
        onAccent: .white,
        separator: Color(nsColor: .separatorColor),
        selection: Color(nsColor: .selectedContentBackgroundColor),
        backgroundNSColor: .windowBackgroundColor)

    /// Colours taken from a terminal scheme. `accentOverride` is the accent chosen in Settings.
    init(theme: TerminalTheme, accentOverride: String? = nil) {
        let dark = theme.isDark
        let bg = TerminalTheme.normalize(theme.background) ?? (dark ? "#1E1E1E" : "#FFFFFF")
        var fg = TerminalTheme.normalize(theme.foreground) ?? (dark ? "#E6E6E6" : "#1D1D1F")
        // Lift faint foregrounds until the chrome text reads.
        let target = dark ? "#FFFFFF" : "#000000"
        var step = 0.15
        while TerminalTheme.contrast(fg, bg) < 4.5, step <= 1.0 {
            fg = TerminalTheme.mix(fg, target, step)
            step += 0.15
        }
        let surface = TerminalTheme.mix(bg, fg, dark ? 0.07 : 0.06)
        let raised = TerminalTheme.mix(bg, fg, dark ? 0.14 : 0.11)
        let separator = TerminalTheme.mix(bg, fg, dark ? 0.24 : 0.2)
        let secondary = TerminalTheme.mix(fg, bg, 0.38)
        let accentHex = accentOverride.flatMap(TerminalTheme.normalize) ?? Self.accent(for: theme, background: bg)
        let selection = TerminalTheme.normalize(theme.selection) ?? TerminalTheme.mix(bg, accentHex, 0.3)

        fromScheme = true
        isDark = dark
        background = Self.color(bg)
        self.surface = AnyShapeStyle(Self.color(surface))
        surfaceColor = Self.color(surface)
        self.raised = Self.color(raised)
        text = Self.color(fg)
        secondaryText = Self.color(secondary)
        accent = Self.color(accentHex)
        onAccent = TerminalTheme.luminance(accentHex) > 0.5 ? Self.color(TerminalTheme.mix(accentHex, "#000000", 0.85)) : .white
        self.separator = Self.color(separator)
        self.selection = Self.color(selection)
        backgroundNSColor = Self.nsColor(bg)
    }

    private init(fromScheme: Bool, isDark: Bool, background: Color, surface: AnyShapeStyle, surfaceColor: Color, raised: Color, text: Color, secondaryText: Color, accent: Color?, onAccent: Color, separator: Color, selection: Color, backgroundNSColor: NSColor) {
        self.fromScheme = fromScheme
        self.isDark = isDark
        self.background = background
        self.surface = surface
        self.surfaceColor = surfaceColor
        self.raised = raised
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.onAccent = onAccent
        self.separator = separator
        self.selection = selection
        self.backgroundNSColor = backgroundNSColor
    }

    /// The scheme's blue when it reads against the background, else cyan, green,
    /// magenta, yellow, red, the cursor colour, and finally a system blue.
    static func accent(for theme: TerminalTheme, background: String) -> String {
        let order = [12, 4, 14, 6, 10, 2, 13, 5, 11, 3, 9, 1]
        for index in order where theme.ansi.indices.contains(index) {
            guard let hex = TerminalTheme.normalize(theme.ansi[index]) else { continue }
            if TerminalTheme.contrast(hex, background) >= 3.0, saturation(hex) >= 0.3 { return hex }
        }
        if let cursor = TerminalTheme.normalize(theme.cursor), TerminalTheme.contrast(cursor, background) >= 3.0, saturation(cursor) >= 0.2 { return cursor }
        return theme.isDark ? "#5AA9FF" : "#0A84FF"
    }

    static func saturation(_ hex: String) -> Double {
        guard let (r, g, b) = TerminalTheme.rgb(hex) else { return 0 }
        let maximum = max(r, g, b), minimum = min(r, g, b)
        return maximum == 0 ? 0 : (maximum - minimum) / maximum
    }

    static func color(_ hex: String) -> Color {
        guard let (r, g, b) = TerminalTheme.rgb(hex) else { return .clear }
        return Color(red: r, green: g, blue: b)
    }

    static func nsColor(_ hex: String) -> NSColor {
        guard let (r, g, b) = TerminalTheme.rgb(hex) else { return .windowBackgroundColor }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette.system
}

extension EnvironmentValues {
    var palette: AppPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Window chrome

/// Paints the hosting window with the palette: its background colour, and a
/// titlebar that lets that colour show through behind the toolbar.
struct WindowChrome: NSViewRepresentable {
    let palette: AppPalette

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        // A translucent terminal owns the window background while it is see-through.
        guard window.isOpaque else { return }
        let color = palette.fromScheme ? palette.backgroundNSColor : NSColor.windowBackgroundColor
        if window.backgroundColor != color { window.backgroundColor = color }
        let transparentTitlebar = palette.fromScheme && window.toolbarStyle != .preference
        if window.titlebarAppearsTransparent != transparentTitlebar { window.titlebarAppearsTransparent = transparentTitlebar }
    }
}

// MARK: - Modifiers

private struct ThemedListModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if palette.fromScheme {
            content
                .scrollContentBackground(.hidden)
                .background(palette.surfaceColor)
                .schemeEdges(palette)
        } else {
            content
        }
    }
}

private struct ThemedFormModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if palette.fromScheme {
            content.scrollContentBackground(.hidden).schemeEdges(palette)
        } else {
            content
        }
    }
}

private struct ThemedSheetModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.presentationBackground(palette.background)
    }
}

private struct SidebarChromeModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if palette.fromScheme {
            content.background(palette.surfaceColor.ignoresSafeArea()).schemeEdges(palette)
        } else {
            content
        }
    }
}

private struct PanelChromeModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if palette.fromScheme {
            content.background(palette.background.ignoresSafeArea()).schemeEdges(palette)
        } else {
            content
        }
    }
}

/// macOS 26 gives every scroll view a "scroll edge" pocket under the toolbar.
/// In full screen the toolbar is its own transparent window, so that pocket
/// paints neutral grey over the scheme colour (behind the title, or across the
/// sidebar's top). With scheme-coloured chrome the surfaces are opaque anyway,
/// so the effect is switched off.
private struct SchemeEdgeModifier: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), hidden {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

extension View {
    /// Hides the toolbar scroll-edge effect while the scheme colours the chrome.
    func schemeEdges(_ palette: AppPalette) -> some View { modifier(SchemeEdgeModifier(hidden: palette.fromScheme)) }
    /// Sidebar-style lists: the scheme's surface colour instead of the vibrancy.
    func themedList() -> some View { modifier(ThemedListModifier()) }
    /// Grouped forms: let the window colour show behind the sections.
    func themedForm() -> some View { modifier(ThemedFormModifier()) }
    /// Sheet content: the sheet takes the window colour of the scheme.
    func themedSheet() -> some View { modifier(ThemedSheetModifier()) }
    /// The sidebar column of a split view, including the area under the toolbar.
    func sidebarChrome() -> some View { modifier(SidebarChromeModifier()) }
    /// An inspector or detail column.
    func panelChrome() -> some View { modifier(PanelChromeModifier()) }
}
