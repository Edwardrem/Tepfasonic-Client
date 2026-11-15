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
        /// `skipped` counts what the folder rules left out, so the message can say why nothing came back.
        case emptyFolder(String, skipped: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) could not be read."
            case .unsupported(let name): "\(name) is not a kind of file Claude can read. Attach images (PNG, JPEG, GIF, WebP, HEIC), PDFs, Word documents or text files such as logs, code, CSV, JSON and Markdown, or a folder of them."
            case .tooLarge(let name, let limit): "\(name) is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit."
            case .empty(let name): "\(name) has no text in it."
            case .emptyFolder(let name, let skipped):
                skipped == 0
                    ? "\(name) has nothing Claude can read: it holds no text files, images or PDFs."
                    : "\(name) has nothing Claude can read: no text files, images or PDFs it could include (\(skipped) other \(skipped == 1 ? "item was" : "items were") skipped)."
            }
        }
    }

    /// Longest side an image is scaled down to before it is sent (Anthropic's sweet spot).
    public static let maxImageDimension: CGFloat = 1568

    // Folder limits: the attach path reads a folder on a background task, but a dropped home
    // folder still must be bounded before anything is read, not after collecting everything.
    /// Entries (files and folders) looked at, at most.
    public static let maxFolderEntries = 2_000
    /// How many folder levels below the one the user chose to look in.
    public static let maxFolderDepth = 12
    /// Largest text file that goes into the bundle. 128 KB is well inside a model context window.
    public static let maxFolderTextFileBytes = 128 * 1024
    /// Largest text bundle for one folder. 400 KB is about 100,000 tokens, under the context window.
    public static let maxFolderBundleBytes = 400 * 1024
    /// Most images and PDFs taken out of one folder.
    public static let maxFolderMediaFiles = 20
    /// Most bytes of images and PDFs taken out of one folder, counted as stored.
    public static let maxFolderMediaBytes = 20 * 1024 * 1024
    /// Largest Word document read from disk; its per-file text limit applies to the extracted text.
    public static let maxFolderWordFileBytes = 10 * 1024 * 1024
    /// Largest Word document attached on its own: only its text is sent, so a report with
    /// screenshots may be large.
    public static let maxWordFileBytes = 64 * 1024 * 1024
    /// Most `word/document.xml` bytes unzip may hand back for one document.
    public static let maxWordDocumentXMLBytes = 8 * 1024 * 1024
    /// Most file paths the bundle's tree lists; the rest become one "… and N more" line.
    public static let maxFolderListedFiles = 300
    /// Most left-out lines the bundle lists; the rest become one "… and N more" line.
    public static let maxFolderListedLeftOut = 200

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
            let text = try wordDocumentText(at: source, name: name, maxBytes: maxWordFileBytes)
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
    /// `maxBytes` is the largest document read: 64 MB on its own, 10 MB when it comes from a folder.
    static func wordDocumentText(at url: URL, name: String, maxBytes: Int) throws -> String {
        // unzip expands wildcards in the archive name by itself, with no shell involved: a file
        // named `*.docx` would open every sibling ending in .docx, symbolic links included. Read
        // the document here and give unzip a private copy whose generated name has no wildcards.
        guard let input = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable(name) }
        let document: Data
        do { document = try input.read(upToCount: maxBytes + 1) ?? Data() } catch {
            try? input.close()
            throw Failure.unreadable(name)
        }
        try? input.close()
        guard document.count <= maxBytes else { throw Failure.tooLarge(name, limit: maxBytes) }

        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do { try document.write(to: temporary, options: [.atomic]) } catch { throw Failure.unreadable(name) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", temporary.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.unreadable(name) }
        // Bound the output too: a crafted archive must not fill memory before the text limit applies.
        var out = Data()
        let output = pipe.fileHandleForReading
        while let chunk = try? output.read(upToCount: 64 * 1024), !chunk.isEmpty {
            out.append(chunk)
            if out.count > maxWordDocumentXMLBytes {
                try? output.close()
                process.terminate()
                process.waitUntilExit()
                throw Failure.tooLarge(name, limit: maxWordDocumentXMLBytes)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !out.isEmpty else { throw Failure.unreadable(name) }
        let text = wordXMLToText(String(decoding: out, as: UTF8.self))
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

    // MARK: Folders

    /// Tuning for one folder import. The public constants above are the defaults; tests pass
    /// smaller ones so every limit is reachable without writing megabytes.
    struct FolderLimits: Sendable {
        var entries = AttachmentImporter.maxFolderEntries
        var depth = AttachmentImporter.maxFolderDepth
        var textFileBytes = AttachmentImporter.maxFolderTextFileBytes
        var bundleBytes = AttachmentImporter.maxFolderBundleBytes
        var mediaFiles = AttachmentImporter.maxFolderMediaFiles
        var mediaBytes = AttachmentImporter.maxFolderMediaBytes
        var wordFileBytes = AttachmentImporter.maxFolderWordFileBytes
        var listedFiles = AttachmentImporter.maxFolderListedFiles
        var listedLeftOut = AttachmentImporter.maxFolderListedLeftOut
    }

    private enum FolderKind {
        case text
        case word
        case media
    }

    private struct FolderItem {
        let url: URL
        let relativePath: String
        let kind: FolderKind
        let byteCount: Int
    }

    private struct FolderWalk {
        var items: [FolderItem] = []
        /// Relative path → why the item is not in the bundle or an attachment of its own.
        var leftOut: [String: String] = [:]
        var visitedEntries = 0
        /// Non-directory entries looked at, symlinks and credentials included.
        var visitedFiles = 0
        /// Hidden files and folders seen; counted, not listed one by one.
        var hiddenSkipped = 0
        /// The entry limit stopped the walk before the folder was finished.
        var truncated = false
    }

    /// Turns a folder into one text bundle (its tree and readable text) plus its images and
    /// PDFs as their own attachments, both in a stable order. Throws when nothing inside can
    /// be read. The copy lives under `directory`, one folder per attachment, as for a file.
    public static func importFolder(at folder: URL, into directory: URL) throws -> [AgentAttachment] {
        try importFolder(at: folder, into: directory, limits: FolderLimits())
    }

    static func importFolder(at folder: URL, into directory: URL, limits: FolderLimits) throws -> [AgentAttachment] {
        let name = folder.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.unreadable(name)
        }

        var walk = walkFolder(at: folder, limits: limits)

        // Media first: the bundle lists what came back as its own attachment, so it has to
        // know each image's and PDF's fate before it is written.
        var mediaAttachments: [AgentAttachment] = []
        var mediaBytes = 0
        // Once one file does not fit, nothing after it can: stop reading and list the rest.
        var mediaBudgetFull = false
        for item in walk.items where item.kind == .media {
            if mediaBudgetFull {
                walk.leftOut[item.relativePath] = "more than \(sizeText(limits.mediaBytes)) of images and PDFs"
                continue
            }
            guard mediaAttachments.count < limits.mediaFiles else {
                walk.leftOut[item.relativePath] = "the \(limits.mediaFiles)-file image and PDF limit was reached"
                continue
            }
            // Before reading, only the per-file cap `importFile` enforces: a heavy photo may
            // shrink to a fraction, so its original size must not use the folder's budget.
            guard item.byteCount <= AgentAttachment.maxPDFBytes else {
                walk.leftOut[item.relativePath] = "larger than \(sizeText(AgentAttachment.maxPDFBytes))"
                continue
            }
            do {
                var attachment = try importFile(at: item.url, into: directory)
                attachment.fileName = item.relativePath
                // Charge the budget with what is stored: a 4 MB photo that became 300 KB costs 300 KB.
                guard mediaBytes + attachment.byteCount <= limits.mediaBytes else {
                    discard(attachment)
                    walk.leftOut[item.relativePath] = "more than \(sizeText(limits.mediaBytes)) of images and PDFs"
                    mediaBudgetFull = true
                    continue
                }
                mediaBytes += attachment.byteCount
                mediaAttachments.append(attachment)
            } catch {
                walk.leftOut[item.relativePath] = reason(for: error)
            }
        }

        let bundle = try folderBundle(named: name, walk: &walk, mediaCount: mediaAttachments.count, into: directory, limits: limits)
        var attachments: [AgentAttachment] = []
        if let bundle { attachments.append(bundle) }
        attachments.append(contentsOf: mediaAttachments)
        guard !attachments.isEmpty else {
            throw Failure.emptyFolder(name, skipped: walk.leftOut.count + walk.hiddenSkipped)
        }
        return attachments
    }

    /// Recursive walk with every rule applied before a file is read. Each directory's entries
    /// are sorted by name so the same folder always gives the same bundle, even when the entry
    /// limit stops the walk.
    private static func walkFolder(at root: URL, limits: FolderLimits) -> FolderWalk {
        var walk = FolderWalk()
        descend(into: root, prefix: "", depth: 0, limits: limits, walk: &walk)
        walk.items.sort { $0.relativePath < $1.relativePath }
        return walk
    }

    private static let heavyFolderNames: Set<String> = ["node_modules", "build", "deriveddata", "pods", "__pycache__", "venv", "dist", "target", "vendor"]
    private static let packageExtensions: Set<String> = ["app", "xcodeproj", "xcworkspace", "framework", "bundle", "playground", "xpc"]
    private static let credentialExtensions: Set<String> = ["pem", "key", "p12", "pfx", "jks", "keystore", "tepfa", "mobileprovision", "ppk", "env"]
    private static let credentialNamePrefixes = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]

    private static func descend(into directory: URL, prefix: String, depth: Int, limits: FolderLimits, walk: inout FolderWalk) {
        guard !walk.truncated else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey, .fileSizeKey]
        let keySet = Set(keys)
        // Pull one directory a few entries at a time instead of listing it whole: a directory
        // with half a million files costs no more than the entry budget still allows.
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in true }) else { return }
        let remaining = max(0, limits.entries - walk.visitedEntries)
        var pulled: [URL] = []
        var sawMore = false
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            guard pulled.count < remaining else {
                sawMore = true
                break
            }
            pulled.append(url)
        }
        pulled.sort { $0.lastPathComponent < $1.lastPathComponent }
        for url in pulled {
            guard walk.visitedEntries < limits.entries else {
                walk.truncated = true
                break
            }
            walk.visitedEntries += 1
            let name = url.lastPathComponent
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            // Hidden files and folders never go in; this also keeps `.env` and `.git` out.
            if name.hasPrefix(".") {
                walk.hiddenSkipped += 1
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                walk.leftOut[relative] = "could not be read"
                continue
            }
            // No symbolic links: they can loop, or point outside the folder the user chose.
            if values.isSymbolicLink == true {
                walk.leftOut[relative] = "symbolic link"
                continue
            }
            if values.isDirectory == true {
                // Packages are whole applications and projects, not notes.
                if values.isPackage == true || packageExtensions.contains(url.pathExtension.lowercased()) {
                    walk.leftOut["\(relative)/"] = "skipped: package"
                    continue
                }
                if heavyFolderNames.contains(name.lowercased()) {
                    walk.leftOut["\(relative)/"] = "skipped: dependency or build output"
                    continue
                }
                if depth + 1 > limits.depth {
                    walk.leftOut[relative] = "deeper than the \(limits.depth)-level limit"
                    continue
                }
                descend(into: url, prefix: relative, depth: depth + 1, limits: limits, walk: &walk)
                continue
            }
            walk.visitedFiles += 1
            // A pipe, socket or device would block a read forever: only regular files go on.
            guard values.isRegularFile == true else {
                walk.leftOut[relative] = "not a regular file"
                continue
            }
            if isCredential(name) {
                walk.leftOut[relative] = "looks like a key or credential"
                continue
            }
            walk.items.append(FolderItem(url: url, relativePath: relative, kind: folderKind(for: url), byteCount: values.fileSize ?? 0))
        }
        if sawMore { walk.truncated = true }
    }

    private static func folderKind(for url: URL) -> FolderKind {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if isWordDocument(type: type, extension: ext) { return .word }
        if ext == "pdf" || type == .pdf { return .media }
        if let type, type.conforms(to: .image) { return .media }
        return .text
    }

    private static func isCredential(_ name: String) -> Bool {
        let lower = name.lowercased()
        if credentialExtensions.contains((lower as NSString).pathExtension) { return true }
        // A public key beside its private half is fine: `id_ed25519.pub` stays.
        guard !lower.hasSuffix(".pub") else { return false }
        return credentialNamePrefixes.contains { lower.hasPrefix($0) }
    }

    /// A file whose text holds a private key is a credential whatever it is called. The text is
    /// at most 128 KB, so the whole of it is searched: a key can sit below a certificate chain.
    static func looksLikePrivateKey(_ text: String) -> Bool {
        if text.hasPrefix("PuTTY-User-Key-File") { return true }
        return text.contains("PRIVATE KEY-----")
    }

    /// The text attachment for a folder: its header, tree, left-out list and readable text. It is
    /// made whenever the folder gives anything at all, so the listing and the reasons a file was
    /// left out survive a folder that only held images.
    private static func folderBundle(named folderName: String, walk: inout FolderWalk, mediaCount: Int, into directory: URL, limits: FolderLimits) throws -> AgentAttachment? {
        // Media that did make it back as attachments are still not part of the bundle.
        for item in walk.items where item.kind == .media && walk.leftOut[item.relativePath] == nil {
            walk.leftOut[item.relativePath] = "sent as a separate attachment"
        }
        let candidates = walk.items.filter { $0.kind != .media }

        // Decide what fits before building anything. The header is estimated with every candidate
        // left out, which is an upper bound (including one removes its line), the contents get the
        // rest, and the text is built once. Half the bundle always stays available for contents.
        let limitReason = "the bundle reached its \(sizeText(limits.bundleBytes)) limit"
        var estimateWalk = walk
        for item in candidates { estimateWalk.leftOut[item.relativePath] = limitReason }
        let estimate = bundleHeader(folderName: folderName, walk: estimateWalk, includedCount: candidates.count + mediaCount, limits: limits)
        let budget = max(limits.bundleBytes - estimate.utf8.count, limits.bundleBytes / 2)
        var bodyUsed = 0
        var included: [(item: FolderItem, text: String)] = []

        for item in candidates {
            let separator = separatorLine(for: item.relativePath)
            let emptyEntry = entryBytes(separator: separator, text: "")
            let text: String
            switch item.kind {
            case .word:
                // A document is gated on its own on-disk size; the text limits below apply to
                // what came out of it, not to the .docx.
                guard item.byteCount <= limits.wordFileBytes else {
                    walk.leftOut[item.relativePath] = "larger than \(sizeText(limits.wordFileBytes))"
                    continue
                }
                guard bodyUsed + emptyEntry <= budget else {
                    walk.leftOut[item.relativePath] = limitReason
                    continue
                }
                guard let extracted = try? wordDocumentText(at: item.url, name: item.relativePath, maxBytes: limits.wordFileBytes), !extracted.isEmpty else {
                    walk.leftOut[item.relativePath] = "could not be read"
                    continue
                }
                guard extracted.utf8.count <= limits.textFileBytes else {
                    walk.leftOut[item.relativePath] = "larger than \(sizeText(limits.textFileBytes))"
                    continue
                }
                text = extracted
            case .text, .media:
                guard item.byteCount <= limits.textFileBytes else {
                    walk.leftOut[item.relativePath] = "larger than \(sizeText(limits.textFileBytes))"
                    continue
                }
                // The resource size is checked before the read; a full bundle stops reading early.
                guard bodyUsed + emptyEntry + item.byteCount <= budget else {
                    walk.leftOut[item.relativePath] = limitReason
                    continue
                }
                guard let data = readBounded(at: item.url, limit: min(limits.textFileBytes, limits.bundleBytes)) else {
                    walk.leftOut[item.relativePath] = "could not be read"
                    continue
                }
                guard !data.isEmpty else {
                    walk.leftOut[item.relativePath] = "empty"
                    continue
                }
                // A known type or extension, or a UTF-8 sniff for anything else; binary is left out.
                guard textMediaType(type: UTType(filenameExtension: item.url.pathExtension.lowercased()), extension: item.url.pathExtension, data: data) != nil else {
                    walk.leftOut[item.relativePath] = "not text"
                    continue
                }
                text = String(decoding: data, as: UTF8.self)
            }
            // The name may look harmless; the text itself decides.
            guard !looksLikePrivateKey(text) else {
                walk.leftOut[item.relativePath] = "looks like a key or credential"
                continue
            }
            let cost = entryBytes(separator: separator, text: text)
            guard bodyUsed + cost <= budget else {
                walk.leftOut[item.relativePath] = limitReason
                continue
            }
            bodyUsed += cost
            included.append((item, text))
        }
        // Nothing readable and nothing to show: the caller turns this into "empty folder".
        guard !included.isEmpty || mediaCount > 0 else { return nil }

        let header = bundleHeader(folderName: folderName, walk: walk, includedCount: included.count + mediaCount, limits: limits)
        let bytes = Data(bundleText(header: header, included: included).utf8)
        let includedCount = included.count + mediaCount
        var note = "folder · \(includedCount) of \(walk.visitedFiles)\(walk.truncated ? "+" : "") files"
        if walk.truncated { note += ", stopped after \(limits.entries) entries" }
        let id = UUID()
        let stored = try store(bytes, named: fileName(folderName, forcingExtension: "txt"), in: directory.appending(path: id.uuidString, directoryHint: .isDirectory))
        return AgentAttachment(id: id, fileName: folderName, mediaType: "text/plain", byteCount: bytes.count, path: stored.path, note: note, folderFileCount: includedCount)
    }

    private static func bundleHeader(folderName: String, walk: FolderWalk, includedCount: Int, limits: FolderLimits) -> String {
        var header = "Folder: \(folderName)\n"
        header += "\(includedCount) of \(walk.visitedFiles)\(walk.truncated ? "+" : "") files included"
        if walk.truncated { header += " (stopped after \(limits.entries) entries)" }
        header += ".\n"
        if walk.hiddenSkipped > 0 {
            header += "\(walk.hiddenSkipped) hidden \(walk.hiddenSkipped == 1 ? "item" : "items") skipped.\n"
        }
        if walk.truncated {
            header += "The folder was not walked to the end, so files beyond that point were not looked at.\n"
        }
        header += "\nFiles:\n"

        let files = walk.items.map(\.relativePath).sorted()
        let leftOut = walk.leftOut.keys.sorted().compactMap { path in walk.leftOut[path].map { "\(path) — \($0)" } }
        let leftOutTitle = leftOut.isEmpty ? "" : "\nLeft out of the bundle (\(leftOut.count)):\n"
        // Keep the header inside half the bundle, so the contents always get the other half and a
        // huge tree can never take the whole budget. The count caps are the hard limit on lines.
        let headerRoom = max(0, limits.bundleBytes / 2 - header.utf8.count - leftOutTitle.utf8.count - 2 * truncationReserve)
        let treeRoom = headerRoom / 2
        let leftOutRoom = headerRoom - treeRoom
        header += cappedList(files, max: limits.listedFiles, room: treeRoom).joined(separator: "\n")
        header += "\n"
        if !leftOutTitle.isEmpty {
            header += leftOutTitle
            header += cappedList(leftOut, max: limits.listedLeftOut, room: leftOutRoom).joined(separator: "\n") + "\n"
        }
        return header
    }

    /// Room kept for the one "… and N more" line a cut list ends with.
    private static let truncationReserve = 64

    /// Header list lines, cut by the count cap and by the bytes left for it, ending with one
    /// "… and N more" line when anything was left out.
    private static func cappedList(_ entries: [String], max: Int, room: Int) -> [String] {
        var lines: [String] = []
        var used = 0
        for entry in entries where lines.count < max {
            let line = "  \(entry)"
            let bytes = line.utf8.count + 1
            guard used + bytes <= room else { break }
            lines.append(line)
            used += bytes
        }
        if lines.count < entries.count {
            lines.append("  … and \(entries.count - lines.count) more")
        }
        return lines
    }

    private static func bundleText(header: String, included: [(item: FolderItem, text: String)]) -> String {
        var text = header
        for entry in included {
            text += "\n" + separatorLine(for: entry.item.relativePath) + entry.text + "\n"
        }
        return text
    }

    /// Bytes one file's section takes in the bundle: the blank line, the separator, the text and
    /// the closing newline. The budget is checked against exactly this.
    private static func entryBytes(separator: String, text: String) -> Int {
        "\n".utf8.count + separator.utf8.count + text.utf8.count + "\n".utf8.count
    }

    private static func separatorLine(for relativePath: String) -> String {
        "===== \(relativePath) =====\n"
    }

    /// Reads at most `limit` bytes: a stale resource size can never turn into an unbounded read.
    private static func readBounded(at url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: max(limit, 1) + 1), data.count <= limit else { return nil }
        return data
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func reason(for error: Error) -> String {
        guard let failure = error as? Failure else { return "could not be read" }
        switch failure {
        case .tooLarge: return "larger than the limit"
        case .unsupported: return "not an image or PDF Claude can read"
        case .empty: return "empty"
        case .emptyFolder: return "nothing Claude can read"
        case .unreadable: return "could not be read"
        }
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
