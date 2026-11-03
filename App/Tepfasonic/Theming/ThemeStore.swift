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
        case system, light, dark
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: "Follow system"
            case .light: "Always light"
            case .dark: "Always dark"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    struct Appearance: Equatable {
        var app: AppAppearance = .system
        /// Hex accent colour; nil follows the system accent.
        var accent: String?
        var compactSidebar = false

        var colorScheme: ColorScheme? { app.colorScheme }
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

    private let context: ModelContext
    private(set) var userThemes: [TerminalTheme] = []
    private(set) var appearance = Appearance()
    /// Bumped when anything that affects the resolved appearance changes.
    private(set) var version = 0
    private(set) var systemIsDark = false
    private var scheduleTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

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
            app: AppAppearance(rawValue: UserDefaults.standard.string(forKey: Self.appAppearanceKey) ?? "") ?? .system,
            accent: UserDefaults.standard.string(forKey: Self.accentKey),
            compactSidebar: UserDefaults.standard.bool(forKey: Self.compactSidebarKey))
        reloadUserThemes()
        systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.systemAppearanceChanged() }
        }
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

    func systemAppearanceChanged() {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark != systemIsDark {
            systemIsDark = dark
            changed()
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
    private static var registered = false

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
