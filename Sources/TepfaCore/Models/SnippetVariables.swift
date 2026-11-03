import Foundation

/// `{{name}}` and `{{name:default value}}` placeholders inside snippet commands.
public enum SnippetVariables {
    public struct Variable: Hashable, Sendable, Identifiable {
        public let name: String
        public let defaultValue: String?

        public var id: String { name }

        public init(name: String, defaultValue: String? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    /// Matches `{{ name }}` or `{{ name : default }}`. Names are identifiers; the
    /// default runs to the closing braces and may contain spaces.
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*(?::([^}]*))?\}\}"#)

    /// Distinct variables in order of first appearance.
    public static func variables(in text: String) -> [Variable] {
        var seen: Set<String> = []
        var out: [Variable] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            guard seen.insert(name).inserted else { continue }
            var defaultValue: String?
            if match.range(at: 2).location != NSNotFound, let defaultRange = Range(match.range(at: 2), in: text) {
                defaultValue = text[defaultRange].trimmingCharacters(in: .whitespaces)
            }
            out.append(Variable(name: name, defaultValue: defaultValue))
        }
        return out
    }

    /// Replaces every placeholder with its value; unknown names fall back to
    /// their default, then to an empty string.
    public static func substitute(_ text: String, values: [String: String]) -> String {
        let mutable = NSMutableString(string: text)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            var replacement = values[name]
            if replacement == nil, match.range(at: 2).location != NSNotFound, let defaultRange = Range(match.range(at: 2), in: text) {
                replacement = text[defaultRange].trimmingCharacters(in: .whitespaces)
            }
            mutable.replaceCharacters(in: match.range, with: replacement ?? "")
        }
        return mutable as String
    }
}
