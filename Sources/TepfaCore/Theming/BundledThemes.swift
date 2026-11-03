import Foundation

public extension TerminalTheme {
    /// The schemes that ship with the app. Ids are stable (`builtin:<slug>`).
    static let bundled: [TerminalTheme] = [
        TerminalTheme(
            id: "builtin:apple-terminal", name: "Apple Terminal", foreground: "#FFFFFF", background: "#1E1E1E", cursor: "#FFFFFF", selection: "#4D4D4D",
            ansi: ["#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD", "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"],
            isDark: true),
        TerminalTheme(
            id: "builtin:apple-terminal-light", name: "Apple Terminal Light", foreground: "#000000", background: "#FFFFFF", cursor: "#4D4D4D", selection: "#B5D5FF",
            ansi: ["#000000", "#C23621", "#25BC24", "#ADAD27", "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD", "#818383", "#FC391F", "#31E722", "#EAEC23", "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"],
            isDark: false),
        TerminalTheme(
            id: "builtin:dracula", name: "Dracula", foreground: "#F8F8F2", background: "#282A36", cursor: "#F8F8F2", cursorText: "#282A36", selection: "#44475A",
            ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"],
            isDark: true),
        TerminalTheme(
            id: "builtin:nord", name: "Nord", foreground: "#D8DEE9", background: "#2E3440", cursor: "#D8DEE9", cursorText: "#2E3440", selection: "#434C5E",
            ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0", "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"],
            isDark: true),
        TerminalTheme(
            id: "builtin:solarized-dark", name: "Solarized Dark", foreground: "#839496", background: "#002B36", bold: "#93A1A1", cursor: "#839496", cursorText: "#002B36", selection: "#073642",
            ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"],
            isDark: true),
        TerminalTheme(
            id: "builtin:solarized-light", name: "Solarized Light", foreground: "#657B83", background: "#FDF6E3", bold: "#586E75", cursor: "#657B83", cursorText: "#FDF6E3", selection: "#EEE8D5",
            ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"],
            isDark: false),
        TerminalTheme(
            id: "builtin:gruvbox-dark", name: "Gruvbox Dark", foreground: "#EBDBB2", background: "#282828", cursor: "#EBDBB2", cursorText: "#282828", selection: "#504945",
            ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984", "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"],
            isDark: true),
        TerminalTheme(
            id: "builtin:gruvbox-light", name: "Gruvbox Light", foreground: "#3C3836", background: "#FBF1C7", cursor: "#3C3836", cursorText: "#FBF1C7", selection: "#D5C4A1",
            ansi: ["#FBF1C7", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#7C6F64", "#928374", "#9D0006", "#79740E", "#B57614", "#076678", "#8F3F71", "#427B58", "#3C3836"],
            isDark: false),
        TerminalTheme(
            id: "builtin:one-dark", name: "One Dark", foreground: "#ABB2BF", background: "#282C34", cursor: "#528BFF", cursorText: "#282C34", selection: "#3E4451",
            ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF", "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"],
            isDark: true),
        TerminalTheme(
            id: "builtin:catppuccin-mocha", name: "Catppuccin Mocha", foreground: "#CDD6F4", background: "#1E1E2E", cursor: "#F5E0DC", cursorText: "#1E1E2E", selection: "#45475A",
            ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE", "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"],
            isDark: true),
        TerminalTheme(
            id: "builtin:catppuccin-latte", name: "Catppuccin Latte", foreground: "#4C4F69", background: "#EFF1F5", cursor: "#DC8A78", cursorText: "#EFF1F5", selection: "#CCD0DA",
            ansi: ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE", "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"],
            isDark: false),
        TerminalTheme(
            id: "builtin:tokyo-night", name: "Tokyo Night", foreground: "#C0CAF5", background: "#1A1B26", cursor: "#C0CAF5", cursorText: "#1A1B26", selection: "#33467C",
            ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6", "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"],
            isDark: true),
        TerminalTheme(
            id: "builtin:monokai", name: "Monokai", foreground: "#F8F8F2", background: "#272822", cursor: "#F8F8F0", cursorText: "#272822", selection: "#49483E",
            ansi: ["#272822", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2", "#75715E", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5"],
            isDark: true),
    ]

    static let defaultDark = bundled[0]
    static let defaultLight = bundled[1]

    static func bundled(id: String) -> TerminalTheme? {
        bundled.first { $0.id == id }
    }
}
