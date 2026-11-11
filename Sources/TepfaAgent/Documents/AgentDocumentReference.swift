import Foundation

/// A file `create_document` wrote, as the panel finds it in the tool result.
/// The result text carries one `<document_created …/>` tag; the model reads
/// the sentence before it, the UI reads the tag.
public struct AgentDocumentReference: Equatable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var format: DocumentFormat
    public var byteCount: Int
    public var pageCount: Int?

    public init(path: String, name: String, format: DocumentFormat, byteCount: Int, pageCount: Int? = nil) {
        self.path = path
        self.name = name
        self.format = format
        self.byteCount = byteCount
        self.pageCount = pageCount
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// "PDF · 3 pages · 42 KB"
    public var summary: String {
        var parts = [format.displayName]
        if let pageCount { parts.append(pageCount == 1 ? "1 page" : "\(pageCount) pages") }
        parts.append(sizeDescription)
        return parts.joined(separator: " · ")
    }

    public var tag: String {
        var attributes = "path=\"\(Self.escape(path))\" name=\"\(Self.escape(name))\" format=\"\(format.rawValue)\" bytes=\"\(byteCount)\""
        if let pageCount { attributes += " pages=\"\(pageCount)\"" }
        return "<document_created \(attributes)/>"
    }

    public static func parse(from text: String) -> AgentDocumentReference? {
        guard let range = text.range(of: #"<document_created\s+[^>]*/>"#, options: .regularExpression) else { return nil }
        let tag = String(text[range])
        func attribute(_ name: String) -> String? {
            guard let match = tag.range(of: "\(name)=\"", options: []) else { return nil }
            let rest = tag[match.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return unescape(String(rest[..<end]))
        }
        guard let path = attribute("path"), let name = attribute("name"), let format = attribute("format").flatMap(DocumentFormat.init(rawValue:)) else { return nil }
        return AgentDocumentReference(path: path, name: name, format: format, byteCount: Int(attribute("bytes") ?? "") ?? 0, pageCount: attribute("pages").flatMap(Int.init))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&amp;", with: "&")
    }
}
