import Foundation

/// A terminal colour scheme: the 16 ANSI colours plus foreground, background,
/// bold, cursor, cursor text and selection colours, all as `#RRGGBB`.
public struct TerminalTheme: Codable, Sendable, Hashable, Identifiable {
    public static let currentFormatVersion = 1

    /// `builtin:<slug>` for bundled schemes, a UUID string for saved ones.
    public var id: String
    public var name: String
    public var foreground: String
    public var background: String
    /// Colour for bold text; nil uses the foreground.
    public var bold: String?
    public var cursor: String
    /// Text colour inside a block cursor; nil uses the background.
    public var cursorText: String?
    public var selection: String
    /// Text colour inside the selection; nil keeps the cell's own colour.
    public var selectionText: String?
    /// 16 ANSI colours: black, red, green, yellow, blue, magenta, cyan, white, then their bright variants.
    public var ansi: [String]
    /// Hint for auto-switching between a light and a dark scheme.
    public var isDark: Bool

    public init(id: String, name: String, foreground: String, background: String, bold: String? = nil, cursor: String, cursorText: String? = nil, selection: String, selectionText: String? = nil, ansi: [String], isDark: Bool) {
        self.id = id
        self.name = name
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.cursor = cursor
        self.cursorText = cursorText
        self.selection = selection
        self.selectionText = selectionText
        self.ansi = ansi
        self.isDark = isDark
    }

    private enum CodingKeys: String, CodingKey {
        case format, id, name, foreground, background, bold, cursor, cursorText, selection, selectionText, ansi, isDark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        foreground = try container.decode(String.self, forKey: .foreground)
        background = try container.decode(String.self, forKey: .background)
        bold = try container.decodeIfPresent(String.self, forKey: .bold)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? foreground
        cursorText = try container.decodeIfPresent(String.self, forKey: .cursorText)
        selection = try container.decodeIfPresent(String.self, forKey: .selection) ?? Self.mix(foreground, background, 0.3)
        selectionText = try container.decodeIfPresent(String.self, forKey: .selectionText)
        let colors = try container.decode([String].self, forKey: .ansi)
        guard colors.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .ansi, in: container, debugDescription: "a theme needs 16 ANSI colours, got \(colors.count)")
        }
        ansi = colors
        isDark = try container.decodeIfPresent(Bool.self, forKey: .isDark) ?? Self.luminance(background) < 0.5
        for value in [foreground, background, cursor, selection] + ansi + [bold, cursorText, selectionText].compactMap({ $0 }) where Self.rgb(value) == nil {
            throw DecodingError.dataCorruptedError(forKey: .ansi, in: container, debugDescription: "\(value) is not a #RRGGBB colour")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("tepfasonic-theme/\(Self.currentFormatVersion)", forKey: .format)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(background, forKey: .background)
        try container.encodeIfPresent(bold, forKey: .bold)
        try container.encode(cursor, forKey: .cursor)
        try container.encodeIfPresent(cursorText, forKey: .cursorText)
        try container.encode(selection, forKey: .selection)
        try container.encodeIfPresent(selectionText, forKey: .selectionText)
        try container.encode(ansi, forKey: .ansi)
        try container.encode(isDark, forKey: .isDark)
    }

    // MARK: JSON

    public static func decode(_ data: Data) throws -> TerminalTheme {
        try JSONDecoder().decode(TerminalTheme.self, from: data)
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public var isBuiltIn: Bool { id.hasPrefix("builtin:") }

    /// A copy with a fresh UUID id, for saving an edited bundled scheme.
    public func asUserTheme(named newName: String? = nil) -> TerminalTheme {
        var copy = self
        copy.id = UUID().uuidString
        if let newName { copy.name = newName }
        return copy
    }

    // MARK: Colour maths

    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text.prefix(6), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        func clamp(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// Relative luminance (0 dark … 1 light).
    public static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = rgb(hex) else { return 0 }
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio between two colours.
    public static func contrast(_ a: String, _ b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `a` blended towards `b` by `amount` (0 = a, 1 = b).
    public static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        guard let ca = rgb(a), let cb = rgb(b) else { return a }
        return hex(r: ca.r + (cb.r - ca.r) * amount, g: ca.g + (cb.g - ca.g) * amount, b: ca.b + (cb.b - ca.b) * amount)
    }

    /// Normalises any accepted spelling (`#abc`, `abcdef`, `#AABBCCDD`) to `#RRGGBB`; nil when invalid.
    public static func normalize(_ hex: String) -> String? {
        rgb(hex).map { self.hex(r: $0.r, g: $0.g, b: $0.b) }
    }
}
