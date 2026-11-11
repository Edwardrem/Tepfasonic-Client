import AppKit
import CoreText
import Foundation
import Observation
import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// App-wide look: the global colour scheme (with light/dark auto-switching),
/// the saved user themes, and the window appearance. Hosts and groups refine
/// the scheme and font through `HostAppearance`.
@MainActor
@Observable
final class ThemeStore {
    enum AutoSwitch: String, CaseIterable, Identifiable {
        /// One scheme, always.
        case off
        /// Follow the macOS appearance with a light and a dark scheme.
        case system
        /// Light scheme between two clock times, dark otherwise.
        case schedule

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .off: "Always use one scheme"
            case .system: "Follow the macOS appearance"
            case .schedule: "Switch on a schedule"
            }
        }
    }

    enum AppAppearance: String, CaseIterable, Identifiable {
        /// Every window goes light or dark with the colour scheme in use.
        case matchScheme
        case system, light, dark
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .matchScheme: "Match the colour scheme"
            case .system: "Follow the system"
            case .light: "Always light"
            case .dark: "Always dark"
            }
        }
        /// The fixed look, or nil when it depends on the scheme or the system.
        var colorScheme: ColorScheme? {
            switch self {
            case .matchScheme, .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    struct Appearance: Equatable {
        var app: AppAppearance = .matchScheme
        /// Hex accent colour; nil follows the system accent.
        var accent: String?
        var compactSidebar = false
        /// Colour the sidebar, bars, panel, sheets and windows with the scheme itself.
        var schemeChrome = true

        var accentColor: Color? { accent.flatMap(HostColor.color) }
    }

    static let globalThemeKey = "theme.global"
    static let lightThemeKey = "theme.light"
    static let darkThemeKey = "theme.dark"
    static let autoSwitchKey = "theme.autoSwitch"
    static let scheduleLightKey = "theme.schedule.light"
    static let scheduleDarkKey = "theme.schedule.dark"
    static let appAppearanceKey = "ui.appearance"
    static let accentKey = "ui.accent"
    static let compactSidebarKey = "ui.compactSidebar"
    static let schemeChromeKey = "ui.schemeChrome"

    private let context: ModelContext
    private(set) var userThemes: [TerminalTheme] = []
    private(set) var appearance = Appearance()
    /// Bumped when anything that affects the resolved appearance changes.
    private(set) var version = 0
    private(set) var systemIsDark = false
    private var scheduleTimer: Timer?

    var globalThemeID: String {
        get { _ = version; return UserDefaults.standard.string(forKey: Self.globalThemeKey) ?? TerminalTheme.defaultDark.id }
        set { UserDefaults.standard.set(newValue, forKey: Self.globalThemeKey); changed() }
    }
    var lightThemeID: String {
        get { _ = version; return UserDefaults.standard.string(forKey: Self.lightThemeKey) ?? TerminalTheme.defaultLight.id }
        set { UserDefaults.standard.set(newValue, forKey: Self.lightThemeKey); changed() }
    }
    var darkThemeID: String {
        get { _ = version; return UserDefaults.standard.string(forKey: Self.darkThemeKey) ?? TerminalTheme.defaultDark.id }
        set { UserDefaults.standard.set(newValue, forKey: Self.darkThemeKey); changed() }
    }
    var autoSwitch: AutoSwitch {
        get { _ = version; return AutoSwitch(rawValue: UserDefaults.standard.string(forKey: Self.autoSwitchKey) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.autoSwitchKey); changed() }
    }
    /// Minutes after midnight when the light scheme starts (schedule mode).
    var scheduleLightStart: Int {
        get { _ = version; return UserDefaults.standard.object(forKey: Self.scheduleLightKey) as? Int ?? 7 * 60 }
        set { UserDefaults.standard.set(newValue, forKey: Self.scheduleLightKey); changed() }
    }
    var scheduleDarkStart: Int {
        get { _ = version; return UserDefaults.standard.object(forKey: Self.scheduleDarkKey) as? Int ?? 19 * 60 }
        set { UserDefaults.standard.set(newValue, forKey: Self.scheduleDarkKey); changed() }
    }

    init(context: ModelContext) {
        self.context = context
        FontCatalog.registerBundledFonts()
        appearance = Appearance(
            app: AppAppearance(rawValue: UserDefaults.standard.string(forKey: Self.appAppearanceKey) ?? "") ?? .matchScheme,
            accent: UserDefaults.standard.string(forKey: Self.accentKey),
            compactSidebar: UserDefaults.standard.bool(forKey: Self.compactSidebarKey),
            schemeChrome: UserDefaults.standard.object(forKey: Self.schemeChromeKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.schemeChromeKey))
        reloadUserThemes()
        systemIsDark = Self.systemPrefersDark
        // The system setting, not the app's own look: once `NSApp.appearance` is
        // forced light or dark, `effectiveAppearance` no longer says what macOS is set to.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemAppearanceChanged() }
        }
        applyWindowAppearance()
        DispatchQueue.main.async { [weak self] in self?.applyWindowAppearance() }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoSwitch == .schedule else { return }
                self.changed()
            }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
    }

    // MARK: Appearance settings

    func setAppAppearance(_ value: AppAppearance) {
        appearance.app = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.appAppearanceKey)
        changed()
    }

    func setAccent(_ hex: String?) {
        appearance.accent = hex
        UserDefaults.standard.set(hex, forKey: Self.accentKey)
        changed()
    }

    func setCompactSidebar(_ value: Bool) {
        appearance.compactSidebar = value
        UserDefaults.standard.set(value, forKey: Self.compactSidebarKey)
        changed()
    }

    func setSchemeChrome(_ value: Bool) {
        appearance.schemeChrome = value
        UserDefaults.standard.set(value, forKey: Self.schemeChromeKey)
        changed()
    }

    /// The colours for the app's chrome right now: the global scheme's when
    /// "colour the whole app" is on, the standard materials otherwise.
    var palette: AppPalette {
        _ = version
        guard appearance.schemeChrome else { return .system }
        return AppPalette(theme: globalTheme, accentOverride: appearance.accent)
    }

    func systemAppearanceChanged() {
        let dark = Self.systemPrefersDark
        if dark != systemIsDark {
            systemIsDark = dark
            changed()
        }
    }

    /// What macOS is set to in System Settings → Appearance (the global defaults domain).
    private static var systemPrefersDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.caseInsensitiveCompare("dark") == .orderedSame
    }

    /// The light or dark look every window should have right now: the scheme's own
    /// when matching it, the system's when following that, or the fixed choice.
    var effectiveColorScheme: ColorScheme? {
        switch appearance.app {
        case .matchScheme: globalTheme.isDark ? .dark : .light
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Pushes the chosen look to every window, sheet, panel and menu at once
    /// (sessions, Files, Theme Editor, Identities, Settings), not just the main window.
    private func applyWindowAppearance() {
        guard let app = NSApp else { return }
        let wanted: NSAppearance.Name? = switch effectiveColorScheme {
        case .dark: .darkAqua
        case .light: .aqua
        default: nil
        }
        if app.appearance?.name != wanted {
            app.appearance = wanted.flatMap { NSAppearance(named: $0) }
        }
    }

    private var lastPreferencesSnapshot = ""

    /// Terminal preferences live in UserDefaults; re-resolve when any of them move.
    private func preferencesChanged() {
        let snapshot = [
            TerminalPreferences.fontName ?? "", String(TerminalPreferences.fontSize), TerminalPreferences.cursorStyle, String(TerminalPreferences.cursorBlink),
            String(TerminalPreferences.antialias), String(TerminalPreferences.minimumContrast), String(TerminalPreferences.backgroundOpacity),
            String(TerminalPreferences.backgroundBlur), String(TerminalPreferences.ligatures), String(TerminalPreferences.lineHeight),
            String(TerminalPreferences.linkNeedsModifier), String(TerminalPreferences.badgeEnabled), TerminalPreferences.badgePosition,
            TerminalPreferences.badgeColor ?? "", String(TerminalPreferences.badgeShowsUser), String(TerminalPreferences.badgeShowsUptime),
        ].joined(separator: "|")
        if snapshot != lastPreferencesSnapshot {
            lastPreferencesSnapshot = snapshot
            changed()
        }
    }

    private func changed() {
        version += 1
        applyWindowAppearance()
    }

    // MARK: Resolution

    /// True when the dark scheme of a pair applies right now.
    var wantsDarkScheme: Bool {
        switch autoSwitch {
        case .off: return TerminalTheme.bundled(id: globalThemeID)?.isDark ?? theme(id: globalThemeID)?.isDark ?? true
        case .system: return systemIsDark
        case .schedule:
            let now = Calendar.current.dateComponents([.hour, .minute], from: .now)
            let minutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)
            if scheduleLightStart <= scheduleDarkStart {
                return !(minutes >= scheduleLightStart && minutes < scheduleDarkStart)
            }
            return minutes >= scheduleDarkStart && minutes < scheduleLightStart
        }
    }

    /// The scheme that applies when a host or group sets none.
    var globalTheme: TerminalTheme {
        _ = version
        switch autoSwitch {
        case .off: return theme(id: globalThemeID) ?? TerminalTheme.defaultDark
        case .system, .schedule: return theme(id: wantsDarkScheme ? darkThemeID : lightThemeID) ?? (wantsDarkScheme ? TerminalTheme.defaultDark : TerminalTheme.defaultLight)
        }
    }

    func theme(id: String) -> TerminalTheme? {
        TerminalTheme.bundled(id: id) ?? userThemes.first { $0.id == id }
    }

    var allThemes: [TerminalTheme] { TerminalTheme.bundled + userThemes }

    /// The appearance for a session: host and group overrides on top of the global settings.
    func resolve(_ host: HostAppearance) -> TerminalAppearance {
        _ = version
        var resolved = TerminalAppearance.global(theme: globalTheme)
        if let id = host.themeID, let theme = theme(id: id) { resolved.theme = theme }
        if let fontName = host.fontName { resolved.fontName = fontName }
        if let fontSize = host.fontSize { resolved.fontSize = fontSize }
        return resolved
    }

    // MARK: User themes

    private func reloadUserThemes() {
        let records = (try? context.fetch(FetchDescriptor<TerminalThemeRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
        userThemes = records.compactMap { record in
            guard var theme = try? TerminalTheme.decode(record.schemeJSON) else { return nil }
            theme.id = record.uuid.uuidString
            theme.name = record.name
            return theme
        }
        changed()
    }

    /// Call after an import so the list picks up new records.
    func refresh() {
        reloadUserThemes()
    }

    @discardableResult
    func save(_ theme: TerminalTheme, source: String = "editor") -> TerminalTheme {
        var stored = theme
        if stored.isBuiltIn || UUID(uuidString: stored.id) == nil { stored.id = UUID().uuidString }
        let id = UUID(uuidString: stored.id)!
        let json = (try? stored.encodedJSON()) ?? Data()
        if let existing = try? context.fetch(FetchDescriptor<TerminalThemeRecord>(predicate: #Predicate { $0.uuid == id })).first {
            existing.name = stored.name
            existing.schemeJSON = json
            existing.updatedAt = .now
        } else {
            context.insert(TerminalThemeRecord(uuid: id, name: stored.name, schemeJSON: json, source: source))
        }
        try? context.save()
        reloadUserThemes()
        return stored
    }

    func delete(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        if let existing = try? context.fetch(FetchDescriptor<TerminalThemeRecord>(predicate: #Predicate { $0.uuid == uuid })).first {
            context.delete(existing)
            try? context.save()
        }
        if globalThemeID == id { globalThemeID = TerminalTheme.defaultDark.id }
        if lightThemeID == id { lightThemeID = TerminalTheme.defaultLight.id }
        if darkThemeID == id { darkThemeID = TerminalTheme.defaultDark.id }
        reloadUserThemes()
    }

    /// Imports a scheme file in any supported format and saves it.
    @discardableResult
    func importTheme(from url: URL) throws -> TerminalTheme {
        let data = try Data(contentsOf: url)
        let theme = try ThemeImporter.theme(from: data, fileName: url.lastPathComponent)
        return save(theme, source: ThemeImporter.sourceName(for: url.lastPathComponent))
    }

    func exportJSON(_ theme: TerminalTheme, to url: URL) throws {
        var shared = theme
        if shared.isBuiltIn { shared.id = UUID().uuidString }
        try shared.encodedJSON().write(to: url, options: [.atomic])
    }
}

/// A theme fetched from a `tepfasonic://theme?url=…` link, shown for confirmation before it is saved.
struct PendingThemeInstall: Identifiable {
    let id = UUID()
    let sourceURL: URL
}

/// Monospace fonts available to the terminal, including the bundled JetBrains Mono.
enum FontCatalog {
    nonisolated(unsafe) private static var registered = false

    /// Registers fonts shipped in the app bundle's `Fonts` folder (process scope).
    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        guard let fontsURL = Bundle.main.url(forResource: "Fonts", withExtension: nil) ?? Bundle.main.resourceURL?.appending(path: "Fonts") else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: fontsURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// Installed monospace families, bundled default first.
    static func monospaceFamilies() -> [String] {
        registerBundledFonts()
        var names = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            if let font = NSFont(name: family, size: 12), font.isFixedPitch {
                names.insert(family)
            }
        }
        for member in NSFontManager.shared.availableFonts where member.lowercased().contains("mono") || member.lowercased().contains("code") {
            if let font = NSFont(name: member, size: 12), font.isFixedPitch, let family = font.familyName {
                names.insert(family)
            }
        }
        var sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if let index = sorted.firstIndex(of: TerminalPreferences.defaultFontName) {
            sorted.remove(at: index)
            sorted.insert(TerminalPreferences.defaultFontName, at: 0)
        }
        return sorted
    }
}
