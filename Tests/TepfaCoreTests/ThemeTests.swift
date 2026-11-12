import Foundation
import Testing
@testable import TepfaCore

@Suite struct TerminalThemeTests {
    @Test func bundledSchemesAreValidAndUnique() throws {
        var ids: Set<String> = []
        for theme in TerminalTheme.bundled {
            #expect(theme.id.hasPrefix("builtin:"))
            #expect(ids.insert(theme.id).inserted)
            #expect(theme.ansi.count == 16)
            for hex in theme.ansi + [theme.foreground, theme.background, theme.cursor, theme.selection] {
                #expect(TerminalTheme.rgb(hex) != nil, "\(theme.name): \(hex)")
            }
            #expect(theme.isDark == (TerminalTheme.luminance(theme.background) < 0.5), Comment(rawValue: theme.name))
            let data = try theme.encodedJSON()
            #expect(try TerminalTheme.decode(data) == theme)
            #expect(TerminalTheme.contrast(theme.foreground, theme.background) >= 3.5, Comment(rawValue: theme.name))
        }
        #expect(TerminalTheme.bundled.count >= 12)
        #expect(TerminalTheme.defaultDark.id == "builtin:lagoon")
        #expect(TerminalTheme.defaultLight.id == "builtin:shoreline")
        #expect(!TerminalTheme.defaultLight.isDark)
        for theme in TerminalTheme.bundled {
            guard let accent = theme.accent else { continue }
            #expect(TerminalTheme.contrast(accent, theme.background) >= 3.0, Comment(rawValue: theme.name))
        }
    }

    @Test func colourMaths() {
        #expect(TerminalTheme.normalize("#abc") == "#AABBCC")
        #expect(TerminalTheme.normalize("112233ff") == "#112233")
        #expect(TerminalTheme.normalize("nope") == nil)
        #expect(TerminalTheme.mix("#000000", "#FFFFFF", 0.5) == "#808080")
        #expect(abs(TerminalTheme.contrast("#000000", "#FFFFFF") - 21) < 0.01)
        #expect(TerminalTheme.luminance("#FFFFFF") == 1)
    }

    @Test func decodingFillsDefaultsAndRejectsBadColours() throws {
        let minimal = """
        {"name":"Mini","foreground":"#eeeeee","background":"#111111","ansi":["#000000","#ff0000","#00ff00","#ffff00","#0000ff","#ff00ff","#00ffff","#ffffff","#555555","#ff5555","#55ff55","#ffff55","#5555ff","#ff55ff","#55ffff","#eeeeee"]}
        """
        let theme = try TerminalTheme.decode(Data(minimal.utf8))
        #expect(theme.cursor == "#eeeeee")
        #expect(theme.isDark)
        #expect(UUID(uuidString: theme.id) != nil)
        #expect(!theme.isBuiltIn)
        let short = minimal.replacingOccurrences(of: ",\"#eeeeee\"]", with: "]")
        #expect(throws: (any Error).self) { try TerminalTheme.decode(Data(short.utf8)) }
        let bad = minimal.replacingOccurrences(of: "#eeeeee\",\"background", with: "zzz\",\"background")
        #expect(throws: (any Error).self) { try TerminalTheme.decode(Data(bad.utf8)) }
    }
}

@Suite struct ThemeImporterTests {
    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    @Test func iTerm2PlistImports() throws {
        var plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
        func entry(_ key: String, _ r: Double, _ g: Double, _ b: Double) -> String {
            "<key>\(key)</key><dict><key>Blue Component</key><real>\(b)</real><key>Green Component</key><real>\(g)</real><key>Red Component</key><real>\(r)</real></dict>"
        }
        for index in 0..<16 { plist += entry("Ansi \(index) Color", Double(index) / 15, 0.5, 0.25) }
        plist += entry("Foreground Color", 1, 1, 1) + entry("Background Color", 0, 0, 0) + entry("Cursor Color", 1, 0, 0) + entry("Selection Color", 0.2, 0.2, 0.2)
        plist += "</dict></plist>"
        let theme = try ThemeImporter.theme(from: Data(plist.utf8), fileName: "My Theme.itermcolors")
        #expect(theme.name == "My Theme")
        #expect(theme.foreground == "#FFFFFF")
        #expect(theme.background == "#000000")
        #expect(theme.cursor == "#FF0000")
        #expect(theme.ansi[15] == "#FF8040")
        #expect(theme.ansi[0] == "#008040")
        #expect(theme.isDark)
    }

    @Test func windowsTerminalAndVSCodeJSONImport() throws {
        var wt: [String: String] = ["name": "WT", "foreground": "#CCCCCC", "background": "#0C0C0C", "cursorColor": "#FFFFFF", "selectionBackground": "#FFFFFF"]
        let keys = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white"]
        for (index, key) in keys.enumerated() {
            wt[key] = String(format: "#%02X0000", index * 10)
            wt["bright" + key.prefix(1).uppercased() + key.dropFirst()] = String(format: "#00%02X00", index * 10)
        }
        let wtData = try JSONSerialization.data(withJSONObject: wt)
        let wtTheme = try ThemeImporter.theme(from: wtData, fileName: "wt.json")
        #expect(wtTheme.name == "WT")
        #expect(wtTheme.ansi[5] == "#320000")
        #expect(wtTheme.ansi[13] == "#003200")

        var colors: [String: String] = ["terminal.foreground": "#ABB2BF", "terminal.background": "#282C34", "terminalCursor.foreground": "#528BFF"]
        for (index, name) in Self.ansiNames.enumerated() {
            colors["terminal.ansi\(name)"] = String(format: "#%02X%02X00", index, index)
            colors["terminal.ansiBright\(name)"] = String(format: "#%02X%02X01", index, index)
        }
        let vscode = "// comment\n{\n  \"name\": \"VS\", /* block */ \"colors\": " + String(decoding: try JSONSerialization.data(withJSONObject: colors), as: UTF8.self) + ",\n}"
        let vsTheme = try ThemeImporter.theme(from: Data(vscode.utf8), fileName: "vs.json")
        #expect(vsTheme.name == "VS")
        #expect(vsTheme.background == "#282C34")
        #expect(vsTheme.cursor == "#528BFF")
        #expect(vsTheme.ansi[9] == "#010101")
    }

    @Test func alacrittyTOMLAndGhosttyImport() throws {
        let toml = """
        # Alacritty
        [colors.primary]
        background = "#1d1f21"
        foreground = "#c5c8c6"
        [colors.cursor]
        cursor = "CellForeground"
        [colors.normal]
        black = "#1d1f21"
        red = "#cc6666"
        green = "#b5bd68"
        yellow = "#f0c674"
        blue = "#81a2be"
        magenta = "#b294bb"
        cyan = "#8abeb7"
        white = "#c5c8c6"
        [colors.bright]
        black = "#969896"
        red = "#cc6666"
        green = "#b5bd68"
        yellow = "#f0c674"
        blue = "#81a2be"
        magenta = "#b294bb"
        cyan = "#8abeb7"
        white = "#ffffff"
        """
        let theme = try ThemeImporter.theme(from: Data(toml.utf8), fileName: "tomorrow-night.toml")
        #expect(theme.name == "tomorrow night")
        #expect(theme.cursor == "#C5C8C6")
        #expect(theme.ansi[1] == "#CC6666")
        #expect(theme.ansi[15] == "#FFFFFF")

        var ghostty = (0..<16).map { "palette = \($0)=#\(String(format: "%02x", $0 * 16))1122" }.joined(separator: "\n")
        ghostty += "\nbackground = 1e1e2e\nforeground = #cdd6f4\ncursor-color = #f5e0dc\nselection-background = #45475a\n"
        let ghost = try ThemeImporter.theme(from: Data(ghostty.utf8), fileName: "mocha")
        #expect(ghost.background == "#1E1E2E")
        #expect(ghost.ansi[2] == "#201122")
        #expect(ghost.selection == "#45475A")
        #expect(ThemeImporter.ghosttyText(ghost).contains("palette = 2=#201122"))
    }

    @Test func alacrittyYAMLImport() throws {
        var yaml = "colors:\n  primary:\n    background: '0x282a36'\n    foreground: '0xf8f8f2'\n  normal:\n"
        for (index, name) in ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"].enumerated() {
            yaml += "    \(name): '0x\(String(format: "%02x", index))0000'\n"
        }
        yaml += "  bright:\n"
        for (index, name) in ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"].enumerated() {
            yaml += "    \(name): '0x00\(String(format: "%02x", index))00'\n"
        }
        let theme = try ThemeImporter.theme(from: Data(yaml.utf8), fileName: "dracula.yml")
        #expect(theme.background == "#282A36")
        #expect(theme.ansi[3] == "#030000")
        #expect(theme.ansi[11] == "#000300")
    }

    @Test func unknownContentIsRejected() {
        #expect(throws: ThemeImporter.Error.unrecognized) { try ThemeImporter.theme(from: Data("hello world".utf8), fileName: "x.txt") }
        #expect(throws: ThemeImporter.Error.unrecognized) { try ThemeImporter.theme(from: Data("{\"a\":1}".utf8), fileName: "x.json") }
    }

    @Test func jsonCommentsAreStrippedOutsideStrings() {
        #expect(ThemeImporter.stripJSONComments("{\"a\":\"http://x\",/*c*/\"b\":1,// tail\n}") == "{\"a\":\"http://x\",\"b\":1}")
    }
}
