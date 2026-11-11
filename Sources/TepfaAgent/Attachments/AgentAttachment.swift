import Foundation

/// A file the user attached to a message: the app keeps its own copy under
/// the data folder and the providers read the bytes when a request is built,
/// so transcripts stay small and the original can move or vanish.
public struct AgentAttachment: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// PNG, JPEG, GIF or WebP, sent as an image block.
        case image
        /// Sent as a PDF document block (Anthropic) or as its extracted text.
        case pdf
        /// Plain text, source code, CSV, JSON, Markdown… sent as text.
        case text
    }

    public var id: UUID
    /// The name the user knows the file by (shown on the chip).
    public var fileName: String
    /// IANA media type of the bytes at `path`.
    public var mediaType: String
    public var byteCount: Int
    /// The app's copy on this Mac.
    public var path: String
    /// Set when the stored bytes are derived from the original (a Word
    /// document's text, a downscaled image).
    public var note: String?

    public init(id: UUID = UUID(), fileName: String, mediaType: String, byteCount: Int, path: String, note: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.path = path
        self.note = note
    }

    public var kind: Kind {
        Self.kind(for: mediaType) ?? .text
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// The stored bytes; throws when the copy is gone.
    public func data() throws -> Data {
        try Data(contentsOf: url)
    }

    public var isMissing: Bool { !FileManager.default.fileExists(atPath: path) }

    /// Media types a model accepts as images.
    public static let imageMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    /// Anthropic's limits: 5 MB per image, 32 MB per PDF; text is kept well under the context size.
    public static let maxImageBytes = 5 * 1024 * 1024
    public static let maxPDFBytes = 32 * 1024 * 1024
    public static let maxTextBytes = 2 * 1024 * 1024

    public static func kind(for mediaType: String) -> Kind? {
        let lower = mediaType.lowercased()
        if imageMediaTypes.contains(lower) { return .image }
        if lower == "application/pdf" { return .pdf }
        if lower.hasPrefix("text/") || textLikeApplicationTypes.contains(lower) { return .text }
        return nil
    }

    static let textLikeApplicationTypes: Set<String> = [
        "application/json", "application/xml", "application/x-yaml", "application/yaml", "application/toml",
        "application/x-sh", "application/x-shellscript", "application/javascript", "application/x-python",
        "application/sql", "application/x-ndjson", "application/ld+json",
    ]

    /// A human-readable size such as "1.2 MB".
    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
