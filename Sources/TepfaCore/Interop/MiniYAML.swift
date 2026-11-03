import Foundation

/// The block-style YAML subset that js-yaml writes for config files: nested
/// maps and sequences by indentation, plain and quoted scalars, empty flow
/// collections, comments. Anchors, tags and multi-line flow are not supported.
public enum MiniYAML {
    public indirect enum Node: Equatable, Sendable {
        case scalar(String?)
        case map([(String, Node)])
        case sequence([Node])

        public static func == (lhs: Node, rhs: Node) -> Bool {
            switch (lhs, rhs) {
            case (.scalar(let a), .scalar(let b)): a == b
            case (.sequence(let a), .sequence(let b)): a == b
            case (.map(let a), .map(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: false
            }
        }

        public subscript(key: String) -> Node? {
            if case .map(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
            return nil
        }

        public var string: String? {
            if case .scalar(let value) = self { return value }
            return nil
        }

        public var int: Int? { string.flatMap { Int($0) } }

        public var array: [Node] {
            if case .sequence(let items) = self { return items }
            return []
        }
    }

    public enum Error: LocalizedError {
        case malformed(line: Int, String)

        public var errorDescription: String? {
            switch self {
            case .malformed(let line, let detail): "YAML line \(line): \(detail)"
            }
        }
    }

    private struct Line {
        let number: Int
        let indent: Int
        let text: String
    }

    public static func parse(_ text: String) throws -> Node {
        var lines: [Line] = []
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).enumerated() {
            let stripped = stripComment(String(raw))
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty, !stripped.hasPrefix("---"), !stripped.hasPrefix("...") else { continue }
            let indent = stripped.prefix { $0 == " " }.count
            lines.append(Line(number: index + 1, indent: indent, text: String(stripped.dropFirst(indent)).trimmingCharacters(in: .whitespaces)))
        }
        var index = 0
        guard !lines.isEmpty else { return .map([]) }
        return try parseNode(lines, &index, indent: lines[0].indent)
    }

    private static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var previous: Character = " "
        for (offset, character) in line.enumerated() {
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == "\"" && !inSingle && previous != "\\" { inDouble.toggle() }
            if character == "#" && !inSingle && !inDouble && (offset == 0 || previous == " " || previous == "\t") {
                return String(line.prefix(offset))
            }
            previous = character
        }
        return line
    }

    private static func parseNode(_ lines: [Line], _ index: inout Int, indent: Int) throws -> Node {
        guard index < lines.count else { return .scalar(nil) }
        if lines[index].text.hasPrefix("- ") || lines[index].text == "-" {
            return try parseSequence(lines, &index, indent: indent)
        }
        return try parseMap(lines, &index, indent: indent)
    }

    private static func parseSequence(_ lines: [Line], _ index: inout Int, indent: Int) throws -> Node {
        var items: [Node] = []
        while index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("-") {
            let line = lines[index]
            let rest = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                index += 1
                if index < lines.count, lines[index].indent > indent {
                    items.append(try parseNode(lines, &index, indent: lines[index].indent))
                } else {
                    items.append(.scalar(nil))
                }
            } else if isMapEntry(rest) {
                // "- key: value" starts a map whose remaining keys sit at indent + 2.
                var synthetic = lines
                synthetic[index] = Line(number: line.number, indent: indent + 2, text: rest)
                var subIndex = index
                let node = try parseMap(synthetic, &subIndex, indent: indent + 2)
                index = subIndex
                items.append(node)
            } else {
                items.append(.scalar(scalar(rest)))
                index += 1
            }
        }
        return .sequence(items)
    }

    private static func parseMap(_ lines: [Line], _ index: inout Int, indent: Int) throws -> Node {
        var pairs: [(String, Node)] = []
        while index < lines.count, lines[index].indent == indent, !lines[index].text.hasPrefix("- ") {
            let line = lines[index]
            guard let (key, rest) = splitMapEntry(line.text) else {
                throw Error.malformed(line: line.number, "expected `key: value`")
            }
            if rest.isEmpty {
                index += 1
                if index < lines.count, lines[index].indent > indent {
                    pairs.append((key, try parseNode(lines, &index, indent: lines[index].indent)))
                } else if index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("- ") {
                    // js-yaml writes sequences under a key at the same indent.
                    pairs.append((key, try parseSequence(lines, &index, indent: indent)))
                } else {
                    pairs.append((key, .scalar(nil)))
                }
            } else if rest == "|" || rest == ">" || rest == "|-" || rest == ">-" {
                index += 1
                var block: [String] = []
                let blockIndent = index < lines.count ? lines[index].indent : indent + 1
                while index < lines.count, lines[index].indent >= blockIndent, lines[index].indent > indent {
                    block.append(lines[index].text)
                    index += 1
                }
                pairs.append((key, .scalar(block.joined(separator: rest.hasPrefix("|") ? "\n" : " "))))
            } else {
                pairs.append((key, .scalar(scalar(rest))))
                index += 1
            }
        }
        return .map(pairs)
    }

    private static func isMapEntry(_ text: String) -> Bool {
        splitMapEntry(text) != nil
    }

    private static func splitMapEntry(_ text: String) -> (String, String)? {
        var quoted: Character? = nil
        for (offset, character) in text.enumerated() {
            if let q = quoted {
                if character == q { quoted = nil }
                continue
            }
            if offset == 0, character == "'" || character == "\"" { quoted = character; continue }
            if character == ":" {
                let next = text.index(text.startIndex, offsetBy: offset + 1)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
                    let rest = String(text[next...]).trimmingCharacters(in: .whitespaces)
                    return (unquote(key), rest)
                }
            }
        }
        return nil
    }

    private static func scalar(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" || trimmed == "null" || trimmed == "[]" || trimmed == "{}" { return trimmed == "[]" || trimmed == "{}" ? "" : nil }
        return unquote(trimmed)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("\"") && text.hasSuffix("\"") {
            let inner = String(text.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if text.hasPrefix("'") && text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return text
    }
}
