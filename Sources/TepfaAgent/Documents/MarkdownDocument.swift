import Foundation

/// A small GitHub-flavoured Markdown reader for the documents the agent
/// writes: headings, paragraphs, nested lists, fenced code, quotes, tables,
/// rules, and bold / italic / code / link spans.
public struct MarkdownDocument: Equatable, Sendable {
    public enum Inline: Equatable, Sendable {
        case text(String)
        case bold(String)
        case italic(String)
        case code(String)
        case link(text: String, url: String)

        public var plain: String {
            switch self {
            case .text(let s), .bold(let s), .italic(let s), .code(let s): s
            case .link(let text, _): text
            }
        }
    }

    public struct ListItem: Equatable, Sendable {
        public var level: Int
        public var inlines: [Inline]
        public init(level: Int, inlines: [Inline]) {
            self.level = level
            self.inlines = inlines
        }
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, inlines: [Inline])
        case paragraph([Inline])
        case list(ordered: Bool, items: [ListItem])
        case code(language: String?, text: String)
        case quote([Inline])
        case table(header: [[Inline]], rows: [[[Inline]]])
        case rule
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public init(parsing markdown: String) {
        var parser = Parser(markdown)
        blocks = parser.parse()
    }

    /// The first level-1 heading, for a default title.
    public var firstHeading: String? {
        for block in blocks {
            if case .heading(1, let inlines) = block { return Self.plain(inlines) }
        }
        return nil
    }

    public var plainText: String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let inlines), .paragraph(let inlines), .quote(let inlines): Self.plain(inlines)
            case .list(let ordered, let items):
                items.enumerated().map { index, item in String(repeating: "  ", count: item.level) + (ordered ? "\(index + 1). " : "• ") + Self.plain(item.inlines) }.joined(separator: "\n")
            case .code(_, let text): text
            case .table(let header, let rows): ([header] + rows).map { $0.map(Self.plain).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: "—"
            }
        }.joined(separator: "\n\n")
    }

    public static func plain(_ inlines: [Inline]) -> String {
        inlines.map(\.plain).joined()
    }

    // MARK: Inline spans

    public static func inlines(_ text: String) -> [Inline] {
        var result: [Inline] = []
        var plain = ""
        let chars = Array(text)
        var i = 0
        func flush() {
            if !plain.isEmpty { result.append(.text(plain)); plain = "" }
        }
        func find(_ marker: String, from start: Int) -> Int? {
            let m = Array(marker)
            var j = start
            while j + m.count <= chars.count {
                if Array(chars[j..<(j + m.count)]) == m { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "*_`[]\\#".contains(chars[i + 1]) {
                plain.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                if let end = find("`", from: i + 1) {
                    flush(); result.append(.code(String(chars[(i + 1)..<end]))); i = end + 1; continue
                }
            }
            if c == "*" || c == "_" {
                let double = i + 1 < chars.count && chars[i + 1] == c
                let marker = double ? String([c, c]) : String(c)
                let start = i + marker.count
                if start < chars.count, !chars[start].isWhitespace, let end = find(marker, from: start), end > start,
                   !chars[end - 1].isWhitespace, c == "*" || end + 1 >= chars.count || !chars[end + 1].isLetter {
                    let inner = String(chars[start..<end])
                    flush()
                    result.append(double ? .bold(inner) : .italic(inner))
                    i = end + marker.count
                    continue
                }
            }
            if c == "[", let close = find("](", from: i + 1), let end = find(")", from: close + 2) {
                let label = String(chars[(i + 1)..<close])
                let url = String(chars[(close + 2)..<end])
                if !label.isEmpty, !url.contains(" ") {
                    flush(); result.append(.link(text: label, url: url)); i = end + 1; continue
                }
            }
            plain.append(c)
            i += 1
        }
        flush()
        return result
    }

    // MARK: Blocks

    private struct Parser {
        let lines: [String]
        var index = 0
        var blocks: [Block] = []
        var paragraph: [String] = []

        init(_ text: String) {
            lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        }

        mutating func parse() -> [Block] {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { flushParagraph(); index += 1; continue }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flushParagraph(); parseCode(fence: String(trimmed.prefix(3))); continue }
                if let heading = Self.heading(trimmed) { flushParagraph(); blocks.append(heading); index += 1; continue }
                if Self.isRule(trimmed) { flushParagraph(); blocks.append(.rule); index += 1; continue }
                if trimmed.contains("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) { flushParagraph(); parseTable(); continue }
                if Self.listItem(line) != nil { flushParagraph(); parseList(); continue }
                if trimmed.hasPrefix(">") { flushParagraph(); parseQuote(); continue }
                paragraph.append(trimmed)
                index += 1
            }
            flushParagraph()
            return blocks
        }

        mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(MarkdownDocument.inlines(paragraph.joined(separator: " "))))
            paragraph = []
        }

        static func heading(_ line: String) -> Block? {
            var level = 0
            for c in line { if c == "#" { level += 1 } else { break } }
            guard (1...6).contains(level), line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
            var text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: level, inlines: MarkdownDocument.inlines(text.trimmingCharacters(in: .whitespaces)))
        }

        static func isRule(_ line: String) -> Bool {
            let stripped = line.replacingOccurrences(of: " ", with: "")
            guard stripped.count >= 3 else { return false }
            return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
        }

        static func isTableSeparator(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return false }
            return trimmed.allSatisfy { "|-: ".contains($0) }
        }

        static func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }
            if text.hasSuffix("|") { text.removeLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            for c in text {
                if escaped { current.append(c); escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" } else { current.append(c) }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        /// (indent, ordered, text) for a list line.
        static func listItem(_ line: String) -> (indent: Int, ordered: Bool, text: String)? {
            var indent = 0
            var rest = Substring(line)
            while let first = rest.first, first == " " || first == "\t" {
                indent += first == "\t" ? 4 : 1
                rest.removeFirst()
            }
            guard let first = rest.first else { return nil }
            if "-*+".contains(first), rest.count > 1, rest[rest.index(after: rest.startIndex)] == " " {
                return (indent, false, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
            var digits = ""
            var cursor = rest.startIndex
            while cursor < rest.endIndex, rest[cursor].isNumber, digits.count < 4 { digits.append(rest[cursor]); cursor = rest.index(after: cursor) }
            if !digits.isEmpty, cursor < rest.endIndex, rest[cursor] == "." || rest[cursor] == ")" {
                let after = rest.index(after: cursor)
                if after < rest.endIndex, rest[after] == " " {
                    return (indent, true, String(rest[rest.index(after: after)...]).trimmingCharacters(in: .whitespaces))
                }
            }
            return nil
        }

        mutating func parseCode(fence: String) {
            let opening = lines[index].trimmingCharacters(in: .whitespaces)
            let language = opening.dropFirst(3).trimmingCharacters(in: .whitespaces)
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                body.append(lines[index])
                index += 1
            }
            index += 1
            blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
        }

        mutating func parseTable() {
            let header = Self.cells(lines[index]).map(MarkdownDocument.inlines)
            index += 2
            var rows: [[[Inline]]] = []
            while index < lines.count {
                let line = lines[index]
                guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                var row = Self.cells(line).map(MarkdownDocument.inlines)
                while row.count < header.count { row.append([]) }
                rows.append(Array(row.prefix(header.count)))
                index += 1
            }
            blocks.append(.table(header: header, rows: rows))
        }

        mutating func parseList() {
            guard let first = Self.listItem(lines[index]) else { return }
            let ordered = first.ordered
            let baseIndent = first.indent
            var items: [ListItem] = []
            while index < lines.count {
                let line = lines[index]
                if let item = Self.listItem(line) {
                    if item.indent <= baseIndent, item.ordered != ordered { break }
                    items.append(ListItem(level: max(0, (item.indent - baseIndent) / 2), inlines: MarkdownDocument.inlines(item.text)))
                    index += 1
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t"), var last = items.popLast() {
                    // Continuation of the previous item.
                    last.inlines.append(.text(" "))
                    last.inlines.append(contentsOf: MarkdownDocument.inlines(line.trimmingCharacters(in: .whitespaces)))
                    items.append(last)
                    index += 1
                } else {
                    break
                }
            }
            blocks.append(.list(ordered: ordered, items: items))
        }

        mutating func parseQuote() {
            var text: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { break }
                text.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.quote(MarkdownDocument.inlines(text.joined(separator: " "))))
        }
    }
}
