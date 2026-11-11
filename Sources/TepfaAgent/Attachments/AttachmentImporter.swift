import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a file the user picked or dropped into an `AgentAttachment`: works
/// out what kind it is, converts what the models cannot take (HEIC and huge
/// images become JPEG, Word documents become their text), enforces the size
/// limits and stores a copy under the app's data folder.
public enum AttachmentImporter {
    public enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case unsupported(String)
        case tooLarge(String, limit: Int)
        case empty(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) could not be read."
            case .unsupported(let name): "\(name) is not a kind of file Claude can read. Attach images (PNG, JPEG, GIF, WebP, HEIC), PDFs, Word documents or text files such as logs, code, CSV, JSON and Markdown."
            case .tooLarge(let name, let limit): "\(name) is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit."
            case .empty(let name): "\(name) has no text in it."
            }
        }
    }

    /// Longest side an image is scaled down to before it is sent (Anthropic's sweet spot).
    public static let maxImageDimension: CGFloat = 1568

    /// Copies `source` into `directory/<id>/` and describes it.
    public static func importFile(at source: URL, into directory: URL) throws -> AgentAttachment {
        let name = source.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: source) } catch { throw Failure.unreadable(name) }
        let type = UTType(filenameExtension: source.pathExtension.lowercased())
        let id = UUID()
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)

        if let type, type.conforms(to: .image) {
            let (bytes, mediaType, note) = try prepareImage(data, type: type, name: name)
            let stored = try store(bytes, named: fileName(name, forcingExtension: Self.imageExtension(mediaType)), in: folder)
            return AgentAttachment(id: id, fileName: name, mediaType: mediaType, byteCount: bytes.count, path: stored.path, note: note)
        }
        if type == .pdf || source.pathExtension.lowercased() == "pdf" {
            guard data.count <= AgentAttachment.maxPDFBytes else { throw Failure.tooLarge(name, limit: AgentAttachment.maxPDFBytes) }
            let stored = try store(data, named: fileName(name, forcingExtension: "pdf"), in: folder)
            return AgentAttachment(id: id, fileName: name, mediaType: "application/pdf", byteCount: data.count, path: stored.path)
        }
        if Self.isWordDocument(type: type, extension: source.pathExtension) {
            let text = try wordDocumentText(at: source, name: name)
            let bytes = Data(text.utf8)
            guard bytes.count <= AgentAttachment.maxTextBytes else { throw Failure.tooLarge(name, limit: AgentAttachment.maxTextBytes) }
            let stored = try store(bytes, named: fileName(name, forcingExtension: "txt"), in: folder)
            return AgentAttachment(id: id, fileName: name, mediaType: "text/plain", byteCount: bytes.count, path: stored.path, note: "text extracted from the Word document")
        }
        if let mediaType = textMediaType(type: type, extension: source.pathExtension, data: data) {
            guard data.count <= AgentAttachment.maxTextBytes else { throw Failure.tooLarge(name, limit: AgentAttachment.maxTextBytes) }
            guard !data.isEmpty else { throw Failure.empty(name) }
            let stored = try store(data, named: fileName(name, forcingExtension: nil), in: folder)
            return AgentAttachment(id: id, fileName: name, mediaType: mediaType, byteCount: data.count, path: stored.path)
        }
        throw Failure.unsupported(name)
    }

    /// Deletes the stored copy (when the user removes a chip before sending).
    public static func discard(_ attachment: AgentAttachment) {
        try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
    }

    // MARK: Kinds

    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf", "config",
        "log", "xml", "html", "htm", "css", "sh", "bash", "zsh", "fish", "py", "rb", "js", "mjs", "ts", "tsx", "jsx", "swift", "go",
        "rs", "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs", "php", "pl", "lua", "sql", "r", "scala", "dart", "env",
        "service", "plist", "tf", "hcl", "dockerfile", "makefile", "gradle", "properties", "diff", "patch", "tex", "rst", "org", "adoc",
    ]

    static func textMediaType(type: UTType?, extension ext: String, data: Data) -> String? {
        let lower = ext.lowercased()
        if let type {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
                || type.conforms(to: .yaml) || type.conforms(to: .propertyList) || type.conforms(to: .shellScript) || type.conforms(to: .script) {
                return type.preferredMIMEType ?? "text/plain"
            }
        }
        if textExtensions.contains(lower) {
            switch lower {
            case "md", "markdown": return "text/markdown"
            case "csv": return "text/csv"
            case "json", "jsonl", "ndjson": return "application/json"
            case "html", "htm": return "text/html"
            default: return "text/plain"
            }
        }
        // No name to go by: accept anything that decodes as UTF-8 without NULs.
        let head = data.prefix(8192)
        if !head.isEmpty, !head.contains(0), String(data: head, encoding: .utf8) != nil || String(data: data, encoding: .utf8) != nil {
            return "text/plain"
        }
        return nil
    }

    static func isWordDocument(type: UTType?, extension ext: String) -> Bool {
        if ext.lowercased() == "docx" { return true }
        if let type, let word = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: word) { return true }
        return false
    }

    // MARK: Images

    /// PNG, JPEG, GIF and WebP under the limit go as they are; anything else is re-encoded.
    static func prepareImage(_ data: Data, type: UTType, name: String) throws -> (Data, String, String?) {
        let mediaType = type.preferredMIMEType?.lowercased() ?? ""
        let dimensions = imageDimensions(data)
        let fits = AgentAttachment.imageMediaTypes.contains(mediaType) && data.count <= AgentAttachment.maxImageBytes
            && (dimensions.map { max($0.width, $0.height) <= maxImageDimension } ?? true)
        if fits { return (data, mediaType, nil) }
        guard let encoded = reencode(data) else { throw Failure.unsupported(name) }
        var note = AgentAttachment.imageMediaTypes.contains(mediaType) ? "scaled down for the model" : "converted to JPEG for the model"
        if encoded.count > AgentAttachment.maxImageBytes { throw Failure.tooLarge(name, limit: AgentAttachment.maxImageBytes) }
        if let dimensions, max(dimensions.width, dimensions.height) > maxImageDimension { note = "scaled down for the model" }
        return (encoded, "image/jpeg", note)
    }

    static func imageDimensions(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Decodes, scales the longest side to `maxImageDimension`, and writes JPEG small enough to send.
    static func reencode(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxImageDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for quality in [0.85, 0.7, 0.55, 0.4] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if out.length <= AgentAttachment.maxImageBytes { return out as Data }
        }
        return nil
    }

    static func imageExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }

    // MARK: Word

    /// The paragraphs of `word/document.xml`, one per line (tables become tab-separated rows).
    static func wordDocumentText(at url: URL, name: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.unreadable(name) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw Failure.unreadable(name) }
        let text = wordXMLToText(String(decoding: data, as: UTF8.self))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty(name) }
        return text
    }

    static func wordXMLToText(_ xml: String) -> String {
        var text = xml
        for (tag, replacement) in [("</w:p>", "\n"), ("<w:tab/>", "\t"), ("<w:br/>", "\n"), ("<w:cr/>", "\n"), ("</w:tc>", "\t"), ("</w:tr>", "\n")] {
            text = text.replacingOccurrences(of: tag, with: replacement)
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Storage

    static func fileName(_ original: String, forcingExtension ext: String?) -> String {
        var base = original.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        base = base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        if base.isEmpty { base = "attachment" }
        guard let ext else { return base }
        let stem = (base as NSString).deletingPathExtension
        return (stem.isEmpty ? "attachment" : stem) + "." + ext
    }

    static func store(_ data: Data, named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: name)
        try data.write(to: destination, options: [.atomic])
        return destination
    }
}
