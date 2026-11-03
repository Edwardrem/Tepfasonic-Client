import Foundation

/// Reads colour schemes written by other terminals: iTerm2 `.itermcolors`,
/// Windows Terminal JSON, VS Code themes, Alacritty (TOML or YAML), Ghostty
/// config, and Tepfasonic's own JSON.
public enum ThemeImporter {
    public enum Error: LocalizedError, Equatable {
        case unrecognized
        case incomplete(String)

        public var errorDescription: String? {
            switch self {
            case .unrecognized: "The file is not a colour scheme Tepfasonic can read (iTerm2, Windows Terminal, VS Code, Alacritty, Ghostty or Tepfasonic JSON)."
            case .incomplete(let what): "The scheme is missing \(what)."
            }
        }
    }

    public static func sourceName(for fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".itermcolors") { return "iterm2" }
        if lower.hasSuffix(".toml") || lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") { return "alacritty" }
        if lower.hasSuffix(".json") || lower.hasSuffix(".jsonc") { return "json" }
        return "ghostty"
    }

    /// Detects the format from the content and parses it.
    public static func theme(from data: Data, fileName: String = "") throws -> TerminalTheme {
        let fallbackName = Self.name(fromFileName: fileName)
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") || fileName.lowercased().hasSuffix(".itermcolors") {
                return try iTerm2(data, name: fallbackName)
            }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return try json(data, name: fallbackName)
            }
            if let theme = try? ghostty(text, name: fallbackName) { return theme }
            if let theme = try? alacrittyTOML(text, name: fallbackName) { return theme }
            if let theme = try? alacrittyYAML(text, name: fallbackName) { return theme }
        } else if let theme = try? iTerm2(data, name: fallbackName) {
            return theme
        }
        throw Error.unrecognized
    }

    static func name(fromFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? "Imported" : base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    // MARK: iTerm2

    public static func iTerm2(_ data: Data, name: String) throws -> TerminalTheme {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Error.unrecognized
        }
        func color(_ key: String) -> String? {
            guard let entry = plist[key] as? [String: Any] else { return nil }
            func component(_ name: String) -> Double? {
                (entry[name] as? Double) ?? (entry[name] as? NSNumber)?.doubleValue
            }
            guard let r = component("Red Component"), let g = component("Green Component"), let b = component("Blue Component") else { return nil }
            return TerminalTheme.hex(r: r, g: g, b: b)
        }
        var ansi: [String] = []
        for index in 0..<16 {
            guard let value = color("Ansi \(index) Color") else { throw Error.incomplete("ANSI colour \(index)") }
            ansi.append(value)
        }
        guard let foreground = color("Foreground Color") else { throw Error.incomplete("the foreground colour") }
        guard let background = color("Background Color") else { throw Error.incomplete("the background colour") }
        return TerminalTheme(
            id: UUID().uuidString, name: name, foreground: foreground, background: background,
            bold: color("Bold Color"), cursor: color("Cursor Color") ?? foreground, cursorText: color("Cursor Text Color"),
            selection: color("Selection Color") ?? TerminalTheme.mix(foreground, background, 0.3), selectionText: color("Selected Text Color"),
            ansi: ansi, isDark: TerminalTheme.luminance(background) < 0.5)
    }

    // MARK: JSON (Tepfasonic, Windows Terminal, VS Code)

    public static func json(_ data: Data, name: String) throws -> TerminalTheme {
        if let own = try? TerminalTheme.decode(data) { return own }
        let stripped = stripJSONComments(String(decoding: data, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: Data(stripped.utf8), options: [.fragmentsAllowed]) else {
            throw Error.unrecognized
        }
        if let dictionary = object as? [String: Any] {
            if let colors = dictionary["colors"] as? [String: Any], colors.keys.contains(where: { $0.hasPrefix("terminal.") }) {
                return try vscode(colors, name: (dictionary["name"] as? String) ?? name)
            }
            if dictionary["black"] != nil || dictionary["brightBlack"] != nil {
                return try windowsTerminal(dictionary, name: name)
            }
            if let schemes = dictionary["schemes"] as? [[String: Any]], let first = schemes.first {
                return try windowsTerminal(first, name: name)
            }
        }
        if let array = object as? [[String: Any]], let first = array.first, first["black"] != nil {
            return try windowsTerminal(first, name: name)
        }
        throw Error.unrecognized
    }

    static func windowsTerminal(_ scheme: [String: Any], name: String) throws -> TerminalTheme {
        func color(_ key: String) -> String? { (scheme[key] as? String).flatMap(TerminalTheme.normalize) }
        let order = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white", "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightPurple", "brightCyan", "brightWhite"]
        var ansi: [String] = []
        for key in order {
            guard let value = color(key) ?? (key.contains("Purple") ? color(key.replacingOccurrences(of: "Purple", with: "Magenta")) : nil) ?? (key == "purple" ? color("magenta") : nil) else {
                throw Error.incomplete(key)
            }
            ansi.append(value)
        }
        guard let foreground = color("foreground"), let background = color("background") else { throw Error.incomplete("foreground or background") }
        return TerminalTheme(
            id: UUID().uuidString, name: (scheme["name"] as? String) ?? name, foreground: foreground, background: background,
            cursor: color("cursorColor") ?? foreground, selection: color("selectionBackground") ?? TerminalTheme.mix(foreground, background, 0.3),
            ansi: ansi, isDark: TerminalTheme.luminance(background) < 0.5)
    }

    static func vscode(_ colors: [String: Any], name: String) throws -> TerminalTheme {
        func color(_ key: String) -> String? { (colors[key] as? String).flatMap(TerminalTheme.normalize) }
        let order = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White", "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow", "BrightBlue", "BrightMagenta", "BrightCyan", "BrightWhite"]
        var ansi: [String] = []
        for key in order {
            guard let value = color("terminal.ansi\(key)") else { throw Error.incomplete("terminal.ansi\(key)") }
            ansi.append(value)
        }
        let background = color("terminal.background") ?? color("editor.background") ?? "#1E1E1E"
        let foreground = color("terminal.foreground") ?? color("editor.foreground") ?? "#CCCCCC"
        return TerminalTheme(
            id: UUID().uuidString, name: name, foreground: foreground, background: background,
            cursor: color("terminalCursor.foreground") ?? foreground, cursorText: color("terminalCursor.background"),
            selection: color("terminal.selectionBackground") ?? color("editor.selectionBackground") ?? TerminalTheme.mix(foreground, background, 0.3),
            ansi: ansi, isDark: TerminalTheme.luminance(background) < 0.5)
    }

    /// Removes `//` and `/* */` comments outside strings (VS Code themes are JSONC).
    static func stripJSONComments(_ text: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                out.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                out.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            if character == "/", next < text.endIndex {
                if text[next] == "/" {
                    while index < text.endIndex, !text[index].isNewline { index = text.index(after: index) }
                    continue
                }
                if text[next] == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let close = text.index(after: index)
                        if text[index] == "*", close < text.endIndex, text[close] == "/" {
                            index = text.index(after: close)
                            break
                        }
                        index = close
                    }
                    continue
                }
            }
            out.append(character)
            index = next
        }
        // Trailing commas before } or ] are also tolerated by VS Code.
        return out.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
    }

    // MARK: Alacritty

    public static func alacrittyTOML(_ text: String, name: String) throws -> TerminalTheme {
        var section = ""
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#"), value.hasPrefix("\"") == false, value.hasPrefix("'") == false { value = String(value[..<hash]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            values[section.isEmpty ? key : "\(section).\(key)"] = value
        }
        guard values.keys.contains(where: { $0.hasPrefix("colors.") }) else { throw Error.unrecognized }
        return try alacritty(values: values, name: name)
    }

    public static func alacrittyYAML(_ text: String, name: String) throws -> TerminalTheme {
        let root = try MiniYAML.parse(text)
        guard let colors = root["colors"] else { throw Error.unrecognized }
        var values: [String: String] = [:]
        for group in ["primary", "normal", "bright", "cursor", "selection", "dim"] {
            guard let node = colors[group] else { continue }
            for key in ["background", "foreground", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "cursor", "text"] {
                if let value = node[key]?.string { values["colors.\(group).\(key)"] = value }
            }
        }
        return try alacritty(values: values, name: name)
    }

    static func alacritty(values: [String: String], name: String) throws -> TerminalTheme {
        func color(_ key: String) -> String? {
            guard var value = values[key] else { return nil }
            if value.hasPrefix("0x") { value = "#" + value.dropFirst(2) }
            return TerminalTheme.normalize(value)
        }
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var ansi: [String] = []
        for group in ["normal", "bright"] {
            for colorName in names {
                guard let value = color("colors.\(group).\(colorName)") else { throw Error.incomplete("colors.\(group).\(colorName)") }
                ansi.append(value)
            }
        }
        guard let foreground = color("colors.primary.foreground"), let background = color("colors.primary.background") else {
            throw Error.incomplete("colors.primary")
        }
        let cursor = color("colors.cursor.cursor")
        return TerminalTheme(
            id: UUID().uuidString, name: name, foreground: foreground, background: background,
            cursor: (cursor == nil || values["colors.cursor.cursor"] == "CellForeground") ? foreground : cursor!,
            cursorText: values["colors.cursor.text"] == "CellBackground" ? nil : color("colors.cursor.text"),
            selection: values["colors.selection.background"] == "CellForeground" ? foreground : (color("colors.selection.background") ?? TerminalTheme.mix(foreground, background, 0.3)),
            selectionText: values["colors.selection.text"] == "CellBackground" ? nil : color("colors.selection.text"),
            ansi: ansi, isDark: TerminalTheme.luminance(background) < 0.5)
    }

    // MARK: Ghostty

    public static func ghostty(_ text: String, name: String) throws -> TerminalTheme {
        var palette: [Int: String] = [:]
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if key == "palette" {
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), let hex = TerminalTheme.normalize(parts[1]) { palette[index] = hex }
            } else {
                values[key] = value
            }
        }
        guard palette.count >= 16 || values["background"] != nil else { throw Error.unrecognized }
        var ansi: [String] = []
        for index in 0..<16 {
            guard let value = palette[index] else { throw Error.incomplete("palette entry \(index)") }
            ansi.append(value)
        }
        func color(_ key: String) -> String? { values[key].flatMap(TerminalTheme.normalize) }
        guard let foreground = color("foreground"), let background = color("background") else { throw Error.incomplete("foreground or background") }
        return TerminalTheme(
            id: UUID().uuidString, name: name, foreground: foreground, background: background,
            cursor: color("cursor-color") ?? foreground, cursorText: color("cursor-text"),
            selection: color("selection-background") ?? TerminalTheme.mix(foreground, background, 0.3), selectionText: color("selection-foreground"),
            ansi: ansi, isDark: TerminalTheme.luminance(background) < 0.5)
    }

    // MARK: Export helpers

    /// A Ghostty-compatible config fragment, handy for sharing.
    public static func ghosttyText(_ theme: TerminalTheme) -> String {
        var lines = theme.ansi.enumerated().map { "palette = \($0.offset)=\($0.element.lowercased())" }
        lines += ["background = \(theme.background.lowercased())", "foreground = \(theme.foreground.lowercased())", "cursor-color = \(theme.cursor.lowercased())", "selection-background = \(theme.selection.lowercased())"]
        if let text = theme.cursorText { lines.append("cursor-text = \(text.lowercased())") }
        if let text = theme.selectionText { lines.append("selection-foreground = \(text.lowercased())") }
        return lines.joined(separator: "\n") + "\n"
    }
}
