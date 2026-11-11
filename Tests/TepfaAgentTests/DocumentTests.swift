import Foundation
import PDFKit
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("Markdown documents")
struct MarkdownDocumentTests {
    @Test func parsesBlocks() {
        let markdown = """
        # Disk report

        Servers checked on **three** hosts, see `df -h`.

        ## Findings
        - web-01 is at 91%
          - /var/log is the culprit
        - db-01 is fine

        1. Rotate logs
        2. Add 20 GB

        | Host | Used |
        |------|-----:|
        | web-01 | 91% |
        | db-01 | 40% |

        ```sh
        df -h /
        ```

        > Keep 15% free.

        ---
        Done, see [the runbook](https://example.org/runbook).
        """
        let document = MarkdownDocument(parsing: markdown)
        #expect(document.firstHeading == "Disk report")
        #expect(document.blocks.count == 10)
        guard case .paragraph(let intro) = document.blocks[1] else { Issue.record("expected paragraph"); return }
        #expect(intro == [.text("Servers checked on "), .bold("three"), .text(" hosts, see "), .code("df -h"), .text(".")])
        guard case .list(false, let bullets) = document.blocks[3] else { Issue.record("expected bullets"); return }
        #expect(bullets.map(\.level) == [0, 1, 0])
        guard case .list(true, let numbered) = document.blocks[4] else { Issue.record("expected numbered list"); return }
        #expect(numbered.count == 2)
        guard case .table(let header, let rows) = document.blocks[5] else { Issue.record("expected table"); return }
        #expect(MarkdownDocument.plain(header[1]) == "Used")
        #expect(rows.count == 2)
        guard case .code("sh", "df -h /") = document.blocks[6] else { Issue.record("expected code"); return }
        guard case .quote = document.blocks[7] else { Issue.record("expected quote"); return }
        guard case .rule = document.blocks[8] else { Issue.record("expected rule"); return }
        guard case .paragraph(let outro) = document.blocks[9] else { Issue.record("expected closing paragraph"); return }
        #expect(outro.last == .text("."))
        #expect(outro.contains(.link(text: "the runbook", url: "https://example.org/runbook")))
    }

    @Test func inlineSpans() {
        #expect(MarkdownDocument.inlines("a *b* _c_ **d** `e` [f](https://x.y) \\*g\\*") == [
            .text("a "), .italic("b"), .text(" "), .italic("c"), .text(" "), .bold("d"), .text(" "), .code("e"), .text(" "), .link(text: "f", url: "https://x.y"), .text(" *g*"),
        ])
        #expect(MarkdownDocument.inlines("snake_case_name stays") == [.text("snake_case_name stays")])
        #expect(MarkdownDocument.inlines("2 * 3 * 4") == [.text("2 * 3 * 4")])
    }
}

@Suite("Document rendering")
@MainActor
struct DocumentRendererTests {
    static let sample = """
    ## Summary
    Three hosts were checked. Disk use is **high** on web-01.

    | Host | Used | Free |
    |------|------|------|
    | web-01 | 91% | 4 GB |
    | db-01 | 40% | 120 GB |

    - Rotate `/var/log/nginx`
    - Add storage

    ```
    df -h /
    ```
    """

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tepfa-doc-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pdfHasPagesAndText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendered = try DocumentRenderer.render(markdown: Self.sample, title: "Disk usage report", format: .pdf, to: directory.appending(path: "report.pdf"))
        #expect(rendered.pageCount == 1)
        let pdf = try #require(PDFDocument(url: rendered.url))
        #expect(pdf.pageCount == 1)
        let text = pdf.string ?? ""
        #expect(text.contains("Disk usage report"))
        #expect(text.contains("web-01"))
        #expect(text.contains("Rotate"))
        #expect(text.contains("Page 1 of 1"))
    }

    @Test func longDocumentPaginates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let long = (1...120).map { "Paragraph \($0): " + String(repeating: "lorem ipsum dolor sit amet ", count: 6) }.joined(separator: "\n\n")
        let rendered = try DocumentRenderer.render(markdown: long, title: "Long", format: .pdf, to: directory.appending(path: "long.pdf"))
        #expect((rendered.pageCount ?? 0) >= 3)
        let pdf = try #require(PDFDocument(url: rendered.url))
        #expect(pdf.pageCount == rendered.pageCount)
        #expect(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Paragraph 120") == true)
    }

    @Test func docxIsAValidPackage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendered = try DocumentRenderer.render(markdown: Self.sample + "\n\n1. First\n2. Second\n\nSee [docs](https://example.org).", title: "Disk usage report", format: .docx, to: directory.appending(path: "report.docx"))
        #expect(rendered.byteCount > 1000)
        // Zip magic.
        let data = try Data(contentsOf: rendered.url)
        #expect(data.prefix(2) == Data([0x50, 0x4B]))
        let unpacked = directory.appending(path: "unpacked", directoryHint: .isDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", rendered.url.path, unpacked.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/footer1.xml", "word/_rels/document.xml.rels", "docProps/core.xml"] {
            let url = unpacked.appending(path: part)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(part)")
            // Every part must be well-formed XML.
            _ = try XMLDocument(contentsOf: url)
        }
        let body = try String(contentsOf: unpacked.appending(path: "word/document.xml"), encoding: .utf8)
        #expect(body.contains("<w:pStyle w:val=\"Title\"/>"))
        #expect(body.contains("Disk usage report"))
        #expect(body.contains("<w:tbl>"))
        #expect(body.contains("<w:numId w:val=\"2\"/>"))
        #expect(body.contains("<w:hyperlink r:id=\"rIdLink1\">"))
        let rels = try String(contentsOf: unpacked.appending(path: "word/_rels/document.xml.rels"), encoding: .utf8)
        #expect(rels.contains("https://example.org"))
        // Cocoa's own Word importer must read it back.
        let textutil = Process()
        textutil.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        textutil.arguments = ["-convert", "txt", "-stdout", rendered.url.path]
        let output = Pipe()
        textutil.standardOutput = output
        try textutil.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        textutil.waitUntilExit()
        #expect(textutil.terminationStatus == 0)
        #expect(text.contains("Disk usage report"))
        #expect(text.contains("web-01"))
        #expect(text.contains("Rotate"))
    }

    @Test func htmlMarkdownAndVerbatim() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = try DocumentRenderer.render(markdown: Self.sample, title: "T <1>", format: .html, to: directory.appending(path: "r.html"))
        let page = try String(contentsOf: html.url, encoding: .utf8)
        #expect(page.contains("<title>T &lt;1&gt;</title>"))
        #expect(page.contains("<table>"))
        #expect(page.contains("<strong>high</strong>"))
        let markdown = try DocumentRenderer.render(markdown: Self.sample, title: "Report", format: .md, to: directory.appending(path: "r.md"))
        #expect(try String(contentsOf: markdown.url, encoding: .utf8).hasPrefix("# Report\n\n## Summary"))
        let csv = try DocumentRenderer.render(markdown: "a,b\n1,2\n", title: nil, format: .csv, to: directory.appending(path: "r.csv"))
        #expect(try String(contentsOf: csv.url, encoding: .utf8) == "a,b\n1,2\n")
    }

    @Test func toolWritesIntoTheDocumentsFolderWithoutOverwriting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let runner = AgentToolRunner(host: host, source: .agentPanel)
        runner.documentsDirectory = directory
        let input: JSONValue = ["file_name": "Disk report.pdf", "format": "pdf", "title": "Disk report", "content": .string(Self.sample)]
        let first = await runner.call(name: "create_document", input: input)
        #expect(!first.isError)
        let reference = try #require(AgentDocumentReference.parse(from: first.content))
        #expect(reference.name == "Disk report.pdf")
        #expect(reference.format == .pdf)
        #expect(reference.pageCount == 1)
        #expect(reference.exists)
        #expect(first.content.hasPrefix("Created Disk report.pdf (PDF · 1 page"))
        let second = await runner.call(name: "create_document", input: input)
        let other = try #require(AgentDocumentReference.parse(from: second.content))
        #expect(other.name == "Disk report 2.pdf")
        #expect(host.auditRecords.isEmpty)
        let bad = await runner.call(name: "create_document", input: ["file_name": "x", "format": "xls", "content": "a"])
        #expect(bad.isError)
        #expect(bad.content.contains("format"))
    }

    @Test func documentStemIsSafe() {
        #expect(AgentToolRunner.documentStem("../etc/passwd.PDF", format: .pdf) == "-etc-passwd")
        #expect(AgentToolRunner.documentStem("  ", format: .docx) == "Document")
        #expect(AgentToolRunner.documentStem("Report.docx", format: .docx) == "Report")
        #expect(AgentToolRunner.documentStem("Report.docx", format: .pdf) == "Report")
    }

    @Test func referenceTagRoundTrips() {
        let reference = AgentDocumentReference(path: "/tmp/a \"b\"/c.docx", name: "c.docx", format: .docx, byteCount: 1234, pageCount: nil)
        let parsed = AgentDocumentReference.parse(from: "Created c.docx.\n" + reference.tag)
        #expect(parsed == reference)
        #expect(AgentDocumentReference.parse(from: "no tag here") == nil)
    }
}

@Suite("Attachments")
struct AttachmentTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tepfa-attach-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A tiny PNG (1×1 red pixel).
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    @Test func importsTextImagesAndRejectsUnknownBinaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "nginx.log")
        try Data("GET / 200\nGET /x 404\n".utf8).write(to: log)
        let text = try AttachmentImporter.importFile(at: log, into: directory.appending(path: "store"))
        #expect(text.kind == .text)
        #expect(text.fileName == "nginx.log")
        #expect(text.byteCount == 21)
        #expect(try text.data() == Data("GET / 200\nGET /x 404\n".utf8))

        let image = directory.appending(path: "shot.png")
        try Self.png.write(to: image)
        let picture = try AttachmentImporter.importFile(at: image, into: directory.appending(path: "store"))
        #expect(picture.kind == .image)
        #expect(picture.mediaType == "image/png")
        #expect(picture.note == nil)

        let binary = directory.appending(path: "blob.bin")
        try Data([0, 1, 2, 3, 0xFF, 0]).write(to: binary)
        #expect(throws: AttachmentImporter.Failure.unsupported("blob.bin")) {
            try AttachmentImporter.importFile(at: binary, into: directory.appending(path: "store"))
        }
        #expect(AttachmentImporter.textMediaType(type: nil, extension: "", data: Data("plain words".utf8)) == "text/plain")
        #expect(AttachmentImporter.textMediaType(type: nil, extension: "csv", data: Data()) == "text/csv")
    }

    @Test func wordXMLBecomesText() {
        let xml = "<w:document><w:body><w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:t xml:space=\"preserve\"> &amp; welcome</w:t></w:r></w:p><w:p><w:r><w:t>Second</w:t></w:r></w:p></w:body></w:document>"
        #expect(AttachmentImporter.wordXMLToText(xml) == "Hello & welcome\nSecond")
    }

    @Test func blocksEncodeAndSerialiseForBothProviders() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imagePath = directory.appending(path: "a.png")
        try Self.png.write(to: imagePath)
        let textPath = directory.appending(path: "notes.txt")
        try Data("line one".utf8).write(to: textPath)
        let image = AgentAttachment(fileName: "a.png", mediaType: "image/png", byteCount: Self.png.count, path: imagePath.path)
        let notes = AgentAttachment(fileName: "notes.txt", mediaType: "text/plain", byteCount: 8, path: textPath.path)
        let missing = AgentAttachment(fileName: "gone.pdf", mediaType: "application/pdf", byteCount: 1, path: directory.appending(path: "gone.pdf").path)
        let message = AgentMessage.user("What is wrong here?", attachments: [image, notes, missing])
        #expect(message.attachments.count == 3)
        #expect(message.text == "What is wrong here?")

        // Transcript round trip.
        let data = try AgentTranscript.encode([message])
        let decoded = try AgentTranscript.decode(data)
        #expect(decoded.map(\.blocks) == [message.blocks])

        // Anthropic: image, document (text source), a note for the missing file, then the question.
        let anthropic = AnthropicProvider.messagesJSON([message])
        let content = try #require(anthropic.arrayValue?.first?["content"]?.arrayValue)
        #expect(content.count == 4)
        #expect(content[0]["type"]?.stringValue == "image")
        #expect(content[0]["source"]?["media_type"]?.stringValue == "image/png")
        #expect(content[0]["source"]?["data"]?.stringValue == Self.png.base64EncodedString())
        #expect(content[1]["type"]?.stringValue == "document")
        #expect(content[1]["source"]?["type"]?.stringValue == "text")
        #expect(content[1]["source"]?["data"]?.stringValue == "line one")
        #expect(content[1]["title"]?.stringValue == "notes.txt")
        #expect(content[2]["type"]?.stringValue == "text")
        #expect(content[2]["text"]?.stringValue?.contains("gone.pdf") == true)
        #expect(content[3]["text"]?.stringValue == "What is wrong here?")

        // OpenAI-compatible: a content array with an image_url data URI and inline text.
        let openAI = OpenAICompatibleProvider.messagesJSON([message])
        let parts = try #require(openAI.first?["content"]?.arrayValue)
        #expect(parts.count == 4)
        #expect(parts[0]["type"]?.stringValue == "image_url")
        #expect(parts[0]["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        #expect(parts[1]["text"]?.stringValue?.contains("<attachment name=\"notes.txt\"") == true)
        #expect(parts[3]["text"]?.stringValue == "What is wrong here?")

        // Plain text messages keep the string form.
        #expect(OpenAICompatibleProvider.messagesJSON([.user("hi")]).first?["content"]?.stringValue == "hi")
    }

    @Test @MainActor func sessionSendsAttachmentsBeforeText() async throws {
        let provider = FakeProvider(responses: [FakeProvider.reply("Looks like a 404 storm.")])
        let host = FakeToolHost(hosts: [FakeToolHost.web])
        let session = AgentSession(provider: provider, systemPrompt: "test", toolRunner: AgentToolRunner(host: host, source: .agentPanel))
        let file = AgentAttachment(fileName: "x.log", mediaType: "text/plain", byteCount: 3, path: "/nonexistent/x.log")
        session.send("", attachments: [file])
        while session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.messages.count == 2)
        #expect(session.messages[0].blocks == [.attachment(file)])
        #expect(provider.requests.first?.messages.first?.attachments == [file])
    }
}
