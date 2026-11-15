import Darwin
import Foundation
import Testing
@testable import TepfaAgent

/// A folder attached from the open panel or a drop: one text bundle plus the images and PDFs
/// inside, behind a walk that never leaves the folder or reads more than its limits allow.
@Suite("Folder import")
struct FolderImportTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tepfa-folder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ text: String, to directory: URL, _ path: String) throws -> URL {
        try write(Data(text.utf8), to: directory, path)
    }

    @discardableResult
    private func write(_ data: Data, to directory: URL, _ path: String) throws -> URL {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func text(of attachment: AgentAttachment) throws -> String {
        String(decoding: try attachment.data(), as: UTF8.self)
    }

    /// A tiny PNG (1×1 red pixel).
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    /// A real `.docx` (a zip with `word/document.xml`) built with `/usr/bin/zip`.
    private func makeDocx(in directory: URL, text: String, extraByteCount: Int = 0, uncompressed: Bool = false) throws -> Data {
        let xml = "<w:document><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>"
        return try makeDocx(in: directory, documentXML: xml, extraByteCount: extraByteCount, uncompressed: uncompressed)
    }

    private func makeDocx(in directory: URL, documentXML: String, extraByteCount: Int = 0, uncompressed: Bool = false) throws -> Data {
        let staging = directory.appending(path: "docx-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(documentXML, to: staging, "word/document.xml")
        if extraByteCount > 0 {
            // Random bytes do not compress, so the document really is that big on disk.
            let filler = uncompressed ? Data(count: extraByteCount) : Data((0..<extraByteCount).map { _ in UInt8.random(in: 0...255) })
            try write(filler, to: staging, "word/media/filler.bin")
        }
        let archive = staging.appending(path: "doc.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "-X"] + (uncompressed ? ["-0"] : []) + [archive.path, "word"]
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try Data(contentsOf: archive)
    }

    /// A 24-bit BMP that ImageIO has to re-encode, so the stored copy is much smaller on disk.
    private static func bitmap(width: Int, height: Int) -> Data {
        let rowSize = (width * 3 + 3) / 4 * 4
        let pixelBytes = rowSize * height
        var data = Data([0x42, 0x4D]) // "BM"
        func append(_ value: UInt32, _ bytes: Int) {
            for index in 0..<bytes { data.append(UInt8((value >> (8 * UInt32(index))) & 0xFF)) }
        }
        func append16(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8(value >> 8))
        }
        append(UInt32(14 + 40 + pixelBytes), 4)
        append16(0)
        append16(0)
        append(UInt32(14 + 40), 4)
        append(UInt32(40), 4)
        append(UInt32(width), 4)
        append(UInt32(height), 4)
        append16(1)
        append16(24)
        append(UInt32(0), 4)
        append(UInt32(pixelBytes), 4)
        append(UInt32(2835), 4)
        append(UInt32(2835), 4)
        append(UInt32(0), 4)
        append(UInt32(0), 4)
        for y in 0..<height {
            for x in 0..<width {
                data.append(UInt8((x * 255) / max(width - 1, 1)))
                data.append(UInt8((y * 255) / max(height - 1, 1)))
                data.append(128)
            }
            for _ in 0..<(rowSize - width * 3) { data.append(0) }
        }
        return data
    }

    @Test func bundleHasHeaderTreeAndAStableOrder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "project", directoryHint: .isDirectory)
        try write("# Notes\n", to: folder, "README.md")
        try write("let a = 1\n", to: folder, "src/a.swift")
        try write("let b = 2\n", to: folder, "src/b.swift")

        let first = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-1"))
        #expect(first.count == 1)
        let bundle = try #require(first.first)
        #expect(bundle.fileName == "project")
        #expect(bundle.kind == .text)
        #expect(bundle.mediaType == "text/plain")
        #expect(bundle.folderFileCount == 3)
        #expect(bundle.note == "folder · 3 of 3 files")

        let body = try text(of: bundle)
        #expect(body.hasPrefix("Folder: project\n"))
        #expect(body.contains("Files:\n  README.md\n  src/a.swift\n  src/b.swift\n"))
        #expect(body.contains("===== README.md =====\n# Notes"))
        #expect(body.contains("===== src/a.swift =====\nlet a = 1"))
        let a = try #require(body.range(of: "===== src/a.swift ====="))
        let b = try #require(body.range(of: "===== src/b.swift ====="))
        #expect(a.lowerBound < b.lowerBound, "files are ordered by relative path")
        #expect(!body.contains("Left out of the bundle"))

        // The same folder always gives the same bundle.
        let second = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-2"))
        let secondBundle = try #require(second.first)
        #expect(try text(of: secondBundle) == body)
        #expect(secondBundle.folderFileCount == 3)
    }

    @Test func nestedFoldersKeepTheirRelativePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "site", directoryHint: .isDirectory)
        try write("body {}\n", to: folder, "assets/css/site.css")
        try write("# Readme\n", to: folder, "docs/guide/readme.md")

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("  assets/css/site.css\n  docs/guide/readme.md\n"))
        #expect(body.contains("===== assets/css/site.css =====\nbody {}"))
        #expect(body.contains("===== docs/guide/readme.md =====\n# Readme"))
    }

    @Test func leavesOutHiddenHeavyPackageSymlinkAndCredentialFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("outside secret\n", to: outside, "outside-secret.txt")

        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try write("keep me\n", to: folder, "notes.md")
        try write("hidden content\n", to: folder, ".hidden.txt")
        try write("[core]\n", to: folder, ".git/config")
        try write("module.exports = 1\n", to: folder, "node_modules/pkg/index.js")
        try write("nested build\n", to: folder, "build/output.txt")
        try write("package\n", to: folder, "App.app/Contents/info.txt")
        try write("PRIVATE KEY\n", to: folder, "id_rsa")
        try write("CERT\n", to: folder, "server.pem")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "outside-link.txt"), withDestinationURL: outside.appending(path: "outside-secret.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "outside-dir"), withDestinationURL: outside)

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        #expect(attachments.count == 1, "only the bundle is importable")
        let body = try text(of: try #require(attachments.first))

        // Nothing from the skipped entries is read into the bundle.
        #expect(body.contains("keep me"))
        #expect(!body.contains("hidden content"))
        #expect(!body.contains("[core]"))
        #expect(!body.contains("module.exports"))
        #expect(!body.contains("output.txt"))
        #expect(!body.contains("Contents/info.txt"))
        #expect(!body.contains("PRIVATE KEY"))
        #expect(!body.contains("outside secret"))

        // Skipped handles are listed with their reason instead of vanishing.
        #expect(body.contains("node_modules/ — skipped: dependency or build output"))
        #expect(body.contains("build/ — skipped: dependency or build output"))
        #expect(body.contains("App.app/ — skipped: package"))
        #expect(body.contains("id_rsa — looks like a key or credential"))
        #expect(body.contains("server.pem — looks like a key or credential"))
        #expect(body.contains("outside-link.txt — symbolic link"))
        #expect(body.contains("outside-dir — symbolic link"))
        #expect(body.contains("2 hidden items skipped."))
    }

    @Test func keysUnderOtherNamesOrWithBackupsAreStillLeftOut() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "keys", directoryHint: .isDirectory)
        try write("keep\n", to: folder, "notes.md")
        // The name hides nothing the content check can miss.
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----\n", to: folder, "deploy_key")
        try write("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n", to: folder, "github_key")
        // Name-based rules: a prefix (even with a backup suffix), a key extension, an env file.
        try write("backup\n", to: folder, "id_rsa.bak")
        try write("PuTTY-User-Key-File-2: ssh-rsa\n", to: folder, "aws.ppk")
        try write("TOKEN=1\n", to: folder, "prod.env")
        // The public half is not a secret, so it stays.
        try write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample user@example\n", to: folder, "id_ed25519.pub")

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        #expect(attachments.count == 1)
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("keep"))
        #expect(body.contains("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample user@example"))
        #expect(!body.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(!body.contains("PuTTY-User-Key-File"))
        for name in ["deploy_key", "github_key", "id_rsa.bak", "aws.ppk", "prod.env"] {
            #expect(body.contains("\(name) — looks like a key or credential"), "\(name) must not be sent")
        }
    }

    @Test func wordGlobNameCannotOpenSiblingsOutsideTheFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideDocument = try makeDocx(in: root, text: "outside secret")
        let outsideURL = try write(outsideDocument, to: outside, "secret.docx")

        let folder = root.appending(path: "glob", directoryHint: .isDirectory)
        // A real document whose *name* makes unzip expand to every sibling `.docx`.
        try write(try makeDocx(in: root, text: "inside document"), to: folder, "*.docx")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked.docx"), withDestinationURL: outsideURL)

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("inside document"))
        #expect(!body.contains("outside secret"), "unzip must only see the one document we copied")
        #expect(body.contains("linked.docx — symbolic link"))
    }

    @Test func wordTextLimitsApplyToTheExtractedTextNotTheDocx() throws {        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "word", directoryHint: .isDirectory)
        // 8 KB on disk, a few words of text: the docx size must not decide.
        let document = try makeDocx(in: root, text: "hello from word", extraByteCount: 8192)
        #expect(document.count > 4096)
        try write(document, to: folder, "report.docx")

        var limits = AttachmentImporter.FolderLimits()
        limits.textFileBytes = 4096
        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-a"), limits: limits)
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("hello from word"))

        // The document itself has its own, separate on-disk cap.
        var strict = AttachmentImporter.FolderLimits()
        strict.wordFileBytes = 10
        #expect(throws: AttachmentImporter.Failure.emptyFolder("word", skipped: 1)) {
            try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-b"), limits: strict)
        }
    }

    @Test func oversizedWordXMLIsRefusedBeforeFillingMemory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "bomb", directoryHint: .isDirectory)
        let document = try makeDocx(in: root, text: String(repeating: "a", count: AttachmentImporter.maxWordDocumentXMLBytes + 1024))
        let url = try write(document, to: folder, "big.docx")
        #expect(throws: AttachmentImporter.Failure.tooLarge("big.docx", limit: AttachmentImporter.maxWordDocumentXMLBytes)) {
            try AttachmentImporter.wordDocumentText(at: url, name: "big.docx", maxBytes: AttachmentImporter.maxWordFileBytes)
        }
    }

    @Test func skipsPipesSoARunAlwaysReturns() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "fifo", directoryHint: .isDirectory)
        try write("keep\n", to: folder, "notes.txt")
        let pipe = folder.appending(path: "pipe.txt")
        #expect(mkfifo(pipe.path, 0o600) == 0)

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("pipe.txt — not a regular file"))
        #expect(!body.contains("===== pipe.txt ====="))
    }

    @Test func perFileAndBundleSizeLimits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "sizes", directoryHint: .isDirectory)
        try write(String(repeating: "x", count: 100), to: folder, "big.log")
        try write("small\n", to: folder, "small.txt")

        var limits = AttachmentImporter.FolderLimits()
        limits.textFileBytes = 16
        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-a"), limits: limits)
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("small"))
        #expect(body.contains("big.log — larger than"))
        #expect(body.contains("Left out of the bundle (1):"))
        #expect(!body.contains(String(repeating: "x", count: 100)))

        // The whole bundle is capped too, including its header and left-out list.
        let second = root.appending(path: "bundle", directoryHint: .isDirectory)
        try write(String(repeating: "a", count: 300), to: second, "a.txt")
        try write(String(repeating: "b", count: 300), to: second, "b.txt")
        try write(String(repeating: "c", count: 300), to: second, "c.txt")
        var tight = AttachmentImporter.FolderLimits()
        tight.bundleBytes = 800
        let limited = try AttachmentImporter.importFolder(at: second, into: root.appending(path: "store-b"), limits: tight)
        let bundle = try #require(limited.first)
        #expect(bundle.byteCount <= 800, "the stored bundle never passes its own limit")
        let limitedBody = try text(of: bundle)
        #expect(limitedBody.contains("===== a.txt ====="))
        #expect(!limitedBody.contains("===== c.txt ====="))
        #expect(limitedBody.contains("— the bundle reached its 800 bytes limit"))
    }

    @Test func entryLimitStopsPullingAndSaysSo() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "many", directoryHint: .isDirectory)
        for index in 0..<40 {
            try write("file \(index)\n", to: folder, String(format: "file-%02d.txt", index))
        }
        var limits = AttachmentImporter.FolderLimits()
        limits.entries = 5

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        let bundle = try #require(attachments.first)
        let body = try text(of: bundle)
        #expect(body.contains("(stopped after 5 entries)"))
        #expect(body.contains("not walked to the end"))
        #expect(bundle.note?.contains("stopped after 5 entries") == true)
        #expect(bundle.note?.contains("+ files") == true)
        // Only the entries the budget allowed were pulled and listed.
        let listed = body.components(separatedBy: "\n").filter { $0.hasPrefix("  file-") }
        #expect(!listed.isEmpty)
        #expect(listed.count <= 5)
    }

    @Test func depthLimitPrunesDeepFolders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "deep", directoryHint: .isDirectory)
        try write("top\n", to: folder, "top.md")
        try write("bottom\n", to: folder, "a/b/c/d/e/bottom.txt")
        var limits = AttachmentImporter.FolderLimits()
        limits.depth = 2

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("top"))
        #expect(!body.contains("bottom"))
        #expect(body.contains("a/b/c — deeper than the 2-level limit"))
    }

    @Test func imagesBecomeTheirOwnAttachmentsWithRelativeNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "shots", directoryHint: .isDirectory)
        try write("# Shots\n", to: folder, "notes.md")
        let imageURL = folder.appending(path: "pics/shot.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.png.write(to: imageURL)

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        #expect(attachments.count == 2)
        let bundle = try #require(attachments.first)
        #expect(bundle.kind == .text)
        #expect(bundle.folderFileCount == 2)
        let body = try text(of: bundle)
        #expect(body.contains("pics/shot.png — sent as a separate attachment"))

        let image = attachments[1]
        #expect(image.kind == .image)
        #expect(image.fileName == "pics/shot.png")
        #expect(image.mediaType == "image/png")
        #expect(try image.data() == Self.png)
        #expect(image.folderFileCount == nil)
    }

    @Test func mediaCountAndByteLimits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "media", directoryHint: .isDirectory)
        try write("notes\n", to: folder, "notes.txt")
        for name in ["a.png", "b.png"] {
            try Self.png.write(to: folder.appending(path: name))
        }

        var countLimits = AttachmentImporter.FolderLimits()
        countLimits.mediaFiles = 1
        let counted = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-a"), limits: countLimits)
        #expect(counted.count == 2, "bundle plus one image")
        let countedBody = try text(of: try #require(counted.first))
        #expect(countedBody.contains("b.png — the 1-file image and PDF limit was reached"))

        var byteLimits = AttachmentImporter.FolderLimits()
        byteLimits.mediaBytes = 10
        let byBytes = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-b"), limits: byteLimits)
        #expect(byBytes.count == 1, "no image fits in 10 bytes")
        let byteBody = try text(of: try #require(byBytes.first))
        #expect(byteBody.contains("a.png — more than 10 bytes of images and PDFs"))
        // The copy made for an image that did not fit is thrown away again.
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "store-b").path)
        #expect(kept.count == 1, "only the bundle's copy is left on disk")
    }

    @Test func mediaBudgetCountsWhatIsStoredNotTheOriginal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "photos", directoryHint: .isDirectory)
        try write("notes\n", to: folder, "notes.txt")
        let bitmap = Self.bitmap(width: 200, height: 200)
        try write(bitmap, to: folder, "shot.bmp")
        #expect(bitmap.count > 100_000, "the original is heavy, the stored JPEG much lighter")

        var limits = AttachmentImporter.FolderLimits()
        limits.mediaBytes = 50_000
        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        #expect(attachments.count == 2, "the stored copy fits even though the original does not")
        let image = attachments[1]
        #expect(image.fileName == "shot.bmp")
        #expect(image.kind == .image)
        #expect(image.byteCount <= 50_000)
    }

    @Test func mediaStopsReadingAfterTheBudgetIsSpent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "media", directoryHint: .isDirectory)
        try write("notes\n", to: folder, "notes.txt")
        try Self.png.write(to: folder.appending(path: "a.png"))
        // Not a decodable image: if it were read it would say "not an image or PDF", so its
        // budget reason proves the loop never opened it.
        try write(Data([0x00, 0x01, 0x02, 0x03]), to: folder, "b.heic")
        try Self.png.write(to: folder.appending(path: "c.png"))

        var limits = AttachmentImporter.FolderLimits()
        limits.mediaBytes = 10
        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        #expect(attachments.count == 1, "only the bundle: not even the first image fits")
        let body = try text(of: try #require(attachments.first))
        for name in ["a.png", "b.heic", "c.png"] {
            #expect(body.contains("\(name) — more than 10 bytes of images and PDFs"), "\(name) is listed with the budget reason")
        }
        #expect(!body.contains("not an image or PDF Claude can read"), "nothing after the first miss was read")
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "store").path)
        #expect(kept.count == 1, "the discarded copy is gone and nothing else was stored")
    }

    @Test func aFolderOfOnlyImagesStillGetsABundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "photos", directoryHint: .isDirectory)
        for name in ["a.png", "b.png", "c.png"] {
            try write(Self.png, to: folder, name)
        }

        var limits = AttachmentImporter.FolderLimits()
        limits.mediaFiles = 2
        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        #expect(attachments.count == 3, "bundle plus the two images that fit")
        let bundle = try #require(attachments.first)
        #expect(bundle.kind == .text)
        #expect(bundle.fileName == "photos")
        #expect(bundle.folderFileCount == 2)
        #expect(bundle.note == "folder · 2 of 3 files")
        let body = try text(of: bundle)
        #expect(body.hasPrefix("Folder: photos\n"))
        #expect(body.contains("a.png — sent as a separate attachment"))
        #expect(body.contains("c.png — the 2-file image and PDF limit was reached"),
                "the left-out list survives a folder with no text")
        #expect(!body.contains("===== "), "there is no readable text to section")
        #expect(attachments[1].fileName == "a.png")
    }

    @Test func aKeyBelowACertificateChainIsStillLeftOut() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "cert", directoryHint: .isDirectory)
        try write("keep\n", to: folder, "notes.md")
        // The key sits well past the first 4 KB, below a certificate chain.
        let chain = String(repeating: "MIIB certificate line\n", count: 300)
        try write(chain + "-----BEGIN RSA PRIVATE KEY-----\nnot-a-real-key\n-----END RSA PRIVATE KEY-----\n", to: folder, "chain.txt")

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        let body = try text(of: try #require(attachments.first))
        #expect(body.contains("keep"))
        #expect(body.contains("chain.txt — looks like a key or credential"))
        #expect(!body.contains("BEGIN RSA PRIVATE KEY"))
    }

    @Test func aWordDocumentOnItsOwnIsAllowedUpTo64MB() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "reports", directoryHint: .isDirectory)
        let document = try makeDocx(in: root, text: "the actual report body", extraByteCount: 11 * 1024 * 1024, uncompressed: true)
        #expect(document.count > AttachmentImporter.maxFolderWordFileBytes)
        let url = try write(document, to: folder, "report.docx")

        // On its own, a big report with screenshots is fine: only its text is sent.
        let imported = try AttachmentImporter.importFile(at: url, into: root.appending(path: "store-file"))
        #expect(imported.kind == .text)
        #expect(try text(of: imported).contains("the actual report body"))

        // From a folder the 10 MB cap still applies.
        #expect(throws: AttachmentImporter.Failure.emptyFolder("reports", skipped: 1)) {
            try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store-folder"))
        }
    }

    @Test func bigTreeIsListedWithCapsAndStillIncludesText() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "big", directoryHint: .isDirectory)
        let longName = String(repeating: "n", count: 60)
        for index in 0..<40 {
            try write(String(repeating: "x", count: 200), to: folder, "\(longName)-\(index).txt")
        }
        var limits = AttachmentImporter.FolderLimits()
        limits.bundleBytes = 3000
        limits.listedFiles = 8
        limits.listedLeftOut = 4

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        let bundle = try #require(attachments.first, "a big tree must not turn into an empty folder")
        let body = try text(of: bundle)
        #expect(bundle.byteCount <= 3000, "the capped header leaves room for the text")
        #expect(body.contains("… and 32 more"), "40 files, 8 listed")
        #expect(body.contains("the bundle reached its"), "files that did not fit say so")
        #expect(body.contains(String(repeating: "x", count: 200)), "readable text is still included")
    }

    @Test func bundleNeverExceedsItsLimitWithManyTinyFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "tiny", directoryHint: .isDirectory)
        for index in 0..<600 {
            try write(String(repeating: "t", count: 300), to: folder, String(format: "f-%03d.txt", index))
        }
        var limits = AttachmentImporter.FolderLimits()
        limits.bundleBytes = 120_000

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"), limits: limits)
        let bundle = try #require(attachments.first)
        // Each section writes a blank line before and a newline after the text; both count.
        #expect(bundle.byteCount <= 120_000, "the stored bundle never passes its own limit")
        let body = try text(of: bundle)
        #expect(body.contains("===== "), "some files made it in")
        #expect(body.contains("… and"), "the lists were cut")
    }

    @Test func skippedHandlesAreReportedWhenNothingIsImportable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "build-only", directoryHint: .isDirectory)
        try write("console.log(1)\n", to: folder, "dist/app.js")
        try write("secret\n", to: folder, ".hidden")

        #expect(throws: AttachmentImporter.Failure.emptyFolder("build-only", skipped: 2)) {
            try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        }
        do {
            _ = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
            Issue.record("expected the folder to be refused")
        } catch let failure as AttachmentImporter.Failure {
            #expect(failure.localizedDescription.contains("2 other items were skipped"), "the message says what was skipped")
        }
    }

    @Test func emptyFolderAndPlainFileFail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: AttachmentImporter.Failure.emptyFolder("empty", skipped: 0)) {
            try AttachmentImporter.importFolder(at: empty, into: root.appending(path: "store-a"))
        }

        let binary = root.appending(path: "binary", directoryHint: .isDirectory)
        try write(Data([0, 1, 2, 3, 0xFF, 0]), to: binary, "blob.bin")
        #expect(throws: AttachmentImporter.Failure.emptyFolder("binary", skipped: 1)) {
            try AttachmentImporter.importFolder(at: binary, into: root.appending(path: "store-b"))
        }

        let file = try write("just a file\n", to: root, "notes.txt")
        #expect(throws: AttachmentImporter.Failure.unreadable("notes.txt")) {
            try AttachmentImporter.importFolder(at: file, into: root.appending(path: "store-c"))
        }
    }

    @Test func oldTranscriptsWithoutTheFolderFieldStillDecode() throws {
        let json = """
        [{"id":"A5A5A5A5-0000-0000-0000-000000000001","role":"user","blocks":[{"type":"attachment","file":{"id":"B5B5B5B5-0000-0000-0000-000000000002","fileName":"notes.txt","mediaType":"text/plain","byteCount":4,"path":"/tmp/notes.txt"}}],"createdAt":"2026-01-02T03:04:05Z"}]
        """
        let messages = try AgentTranscript.decode(Data(json.utf8))
        let attachment = try #require(messages.first?.attachments.first)
        #expect(attachment.fileName == "notes.txt")
        #expect(attachment.folderFileCount == nil)
    }

    @Test func folderAttachmentRoundTripsThroughATranscript() throws {
        let folder = AgentAttachment(fileName: "project", mediaType: "text/plain", byteCount: 12, path: "/tmp/project.txt", note: "folder · 4 of 4 files", folderFileCount: 4)
        let message = AgentMessage.user("What is in here?", attachments: [folder])
        let decoded = try AgentTranscript.decode(try AgentTranscript.encode([message]))
        // The transcript stores dates to the second, so compare the turn's content.
        #expect(decoded.map(\.blocks) == [message.blocks])
        #expect(decoded.first?.attachments.first?.folderFileCount == 4)
        #expect(decoded.first?.attachments.first?.note == "folder · 4 of 4 files")
    }

    @Test func folderFileCountReadsNaturally() {
        let one = AgentAttachment(fileName: "one", mediaType: "text/plain", byteCount: 1, path: "/tmp/one", folderFileCount: 1)
        let many = AgentAttachment(fileName: "many", mediaType: "text/plain", byteCount: 1, path: "/tmp/many", folderFileCount: 12)
        let file = AgentAttachment(fileName: "file", mediaType: "text/plain", byteCount: 1, path: "/tmp/file")
        #expect(one.folderFileCountDescription == "1 file")
        #expect(many.folderFileCountDescription == "12 files")
        #expect(file.folderFileCountDescription == nil)
    }

    @Test func defaultLimitsStayInsideAModelContextWindow() {
        #expect(AttachmentImporter.maxFolderBundleBytes == 400 * 1024)
        #expect(AttachmentImporter.maxFolderTextFileBytes == 128 * 1024)
        #expect(AttachmentImporter.maxWordDocumentXMLBytes == 8 * 1024 * 1024)
        #expect(AttachmentImporter.maxFolderWordFileBytes == 10 * 1024 * 1024)
        #expect(AttachmentImporter.maxWordFileBytes == 64 * 1024 * 1024)
        #expect(AttachmentImporter.maxFolderListedFiles == 300)
        #expect(AttachmentImporter.maxFolderListedLeftOut == 200)
    }

    @Test func anthropicRequestCarriesTheBundleAsATextDocument() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "project", directoryHint: .isDirectory)
        try write("line one\nline two\n", to: folder, "notes.txt")

        let attachments = try AttachmentImporter.importFolder(at: folder, into: root.appending(path: "store"))
        let bundle = try #require(attachments.first)
        let message = AgentMessage.user("Summarise this folder.", attachments: [bundle])
        let messages = AnthropicProvider.messagesJSON([message])
        let content = try #require(messages.arrayValue?.first?["content"]?.arrayValue)
        #expect(content.count == 2)
        #expect(content[0]["type"]?.stringValue == "document")
        #expect(content[0]["title"]?.stringValue == "project")
        #expect(content[0]["source"]?["type"]?.stringValue == "text")
        let document = try #require(content[0]["source"]?["data"]?.stringValue)
        #expect(document.contains("Folder: project"))
        #expect(document.contains("===== notes.txt =====\nline one\nline two"))
        #expect(content[1]["text"]?.stringValue == "Summarise this folder.")
    }
}
