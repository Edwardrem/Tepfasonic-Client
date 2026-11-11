import AppKit
import Foundation

/// File types `create_document` can write.
public enum DocumentFormat: String, CaseIterable, Sendable, Codable {
    case pdf, docx, html, md, txt, csv

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word"
        case .html: "HTML"
        case .md: "Markdown"
        case .txt: "Text"
        case .csv: "CSV"
        }
    }

    public var mediaType: String {
        switch self {
        case .pdf: "application/pdf"
        case .docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .html: "text/html"
        case .md: "text/markdown"
        case .txt: "text/plain"
        case .csv: "text/csv"
        }
    }

    /// Formats whose `content` is written out as it is, not rendered from Markdown.
    public var isVerbatim: Bool { self == .txt || self == .csv }
}

public struct RenderedDocument: Sendable, Equatable {
    public var url: URL
    public var format: DocumentFormat
    public var byteCount: Int
    public var pageCount: Int?
}

/// Writes a Markdown document as PDF (paginated with Cocoa's text system),
/// Word (hand-written OOXML zipped with ditto), HTML, Markdown or plain text.
@MainActor
public enum DocumentRenderer {
    public enum Failure: LocalizedError {
        case zip(String)
        case write(String)

        public var errorDescription: String? {
            switch self {
            case .zip(let detail): "Packaging the Word document failed: \(detail)"
            case .write(let detail): "Writing the document failed: \(detail)"
            }
        }
    }

    public static func render(markdown: String, title: String?, format: DocumentFormat, to url: URL) throws -> RenderedDocument {
        let document = MarkdownDocument(parsing: markdown)
        let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        var pages: Int?
        switch format {
        case .pdf:
            let (pdf, count) = pdfData(document, title: heading)
            data = pdf
            pages = count
        case .docx:
            data = try docxData(document, title: heading)
        case .html:
            data = Data(html(document, title: heading).utf8)
        case .md:
            var text = markdown
            if let heading, !heading.isEmpty, document.firstHeading == nil { text = "# \(heading)\n\n" + markdown }
            data = Data(text.utf8)
        case .txt, .csv:
            data = Data(markdown.utf8)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        return RenderedDocument(url: url, format: format, byteCount: data.count, pageCount: pages)
    }

    // MARK: - PDF

    struct Page {
        static let a4 = CGSize(width: 595.28, height: 841.89)
        static let letter = CGSize(width: 612, height: 792)
        static var size: CGSize { Locale.current.measurementSystem == .us ? letter : a4 }
        static let margin: CGFloat = 56
    }

    public static func pdfData(_ document: MarkdownDocument, title: String?) -> (Data, pages: Int) {
        let pageSize = Page.size
        let content = CGRect(x: Page.margin, y: Page.margin, width: pageSize.width - 2 * Page.margin, height: pageSize.height - 2 * Page.margin - 18)
        let text = attributedString(document, title: title, width: content.width)

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var laidOut = 0
        repeat {
            let container = NSTextContainer(size: content.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 && containers.count > 1 { containers.removeLast(); layout.removeTextContainer(at: containers.count); break }
            laidOut = range.upperBound
        } while laidOut < layout.numberOfGlyphs && containers.count < 400

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return (Data(), 0) }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [kCGPDFContextCreator: "Tepfasonic"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return (Data(), 0) }
        let footerFont = NSFont.systemFont(ofSize: 8.5)
        let footerColor = NSColor(white: 0.45, alpha: 1)
        for (index, container) in containers.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: content.minX, y: Page.margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            let footerY = pageSize.height - Page.margin + 6
            if let title, !title.isEmpty {
                NSAttributedString(string: title, attributes: [.font: footerFont, .foregroundColor: footerColor]).draw(at: CGPoint(x: content.minX, y: footerY))
            }
            let pageLabel = NSAttributedString(string: "Page \(index + 1) of \(containers.count)", attributes: [.font: footerFont, .foregroundColor: footerColor])
            pageLabel.draw(at: CGPoint(x: content.maxX - pageLabel.size().width, y: footerY))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return (data as Data, containers.count)
    }

    // MARK: Attributed text

    private enum Fonts {
        static var body: NSFont { NSFont.systemFont(ofSize: 10.5) }
        static var title: NSFont { NSFont.systemFont(ofSize: 24, weight: .bold) }
        static var code: NSFont { NSFont.monospacedSystemFont(ofSize: 9, weight: .regular) }
        static func heading(_ level: Int) -> NSFont {
            switch level {
            case 1: NSFont.systemFont(ofSize: 18, weight: .bold)
            case 2: NSFont.systemFont(ofSize: 14, weight: .semibold)
            case 3: NSFont.systemFont(ofSize: 12, weight: .semibold)
            default: NSFont.systemFont(ofSize: 11, weight: .semibold)
            }
        }
    }

    private enum Colors {
        static var text: NSColor { NSColor(white: 0.12, alpha: 1) }
        static var secondary: NSColor { NSColor(white: 0.4, alpha: 1) }
        static var rule: NSColor { NSColor(white: 0.78, alpha: 1) }
        static var codeBackground: NSColor { NSColor(red: 0.955, green: 0.96, blue: 0.97, alpha: 1) }
        static var headerBackground: NSColor { NSColor(red: 0.94, green: 0.945, blue: 0.955, alpha: 1) }
        static var link: NSColor { NSColor(red: 0.05, green: 0.4, blue: 0.85, alpha: 1) }
    }

    static func attributedString(_ document: MarkdownDocument, title: String?, width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func style(before: CGFloat = 0, after: CGFloat = 6, head: CGFloat = 0, firstLine: CGFloat = 0, tabs: [CGFloat] = [], lineHeight: CGFloat = 1.18) -> NSMutableParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = before
            paragraph.paragraphSpacing = after
            paragraph.headIndent = head
            paragraph.firstLineHeadIndent = firstLine
            paragraph.lineHeightMultiple = lineHeight
            paragraph.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
            paragraph.lineBreakMode = .byWordWrapping
            return paragraph
        }
        func append(_ inlines: [MarkdownDocument.Inline], font: NSFont, color: NSColor = Colors.text, paragraph: NSParagraphStyle, extra: [NSAttributedString.Key: Any] = [:]) {
            for inline in inlines {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                for (key, value) in extra { attributes[key] = value }
                switch inline {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .bold(let text):
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .italic(let text):
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .code(let text):
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                    attributes[.backgroundColor] = Colors.codeBackground
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .link(let text, let url):
                    attributes[.foregroundColor] = Colors.link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    if let link = URL(string: url) { attributes[.link] = link }
                    result.append(NSAttributedString(string: text, attributes: attributes))
                }
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }

        if let title, !title.isEmpty {
            append([.text(title)], font: Fonts.title, paragraph: style(after: 2, lineHeight: 1.1))
            let date = Date.now.formatted(date: .long, time: .omitted)
            append([.text(date)], font: NSFont.systemFont(ofSize: 9.5), color: Colors.secondary, paragraph: style(after: 14))
        }

        for block in document.blocks {
            switch block {
            case .heading(let level, let inlines):
                append(inlines, font: Fonts.heading(level), paragraph: style(before: level == 1 ? 14 : 10, after: level == 1 ? 6 : 4, lineHeight: 1.1))
            case .paragraph(let inlines):
                append(inlines, font: Fonts.body, paragraph: style(after: 7))
            case .quote(let inlines):
                let quote = NSTextBlock()
                quote.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(Colors.rule)
                quote.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                quote.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
                quote.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
                let paragraph = style(after: 8)
                paragraph.textBlocks = [quote]
                append(inlines, font: NSFontManager.shared.convert(Fonts.body, toHaveTrait: .italicFontMask), color: Colors.secondary, paragraph: paragraph)
            case .list(let ordered, let items):
                var counters: [Int: Int] = [:]
                for (index, item) in items.enumerated() {
                    counters[item.level, default: 0] += 1
                    for deeper in counters.keys where deeper > item.level { counters[deeper] = 0 }
                    let indent = CGFloat(item.level) * 16
                    let marker = ordered ? "\(counters[item.level] ?? 1)." : (item.level == 0 ? "•" : (item.level == 1 ? "◦" : "▪"))
                    let last = index == items.count - 1
                    let paragraph = style(after: last ? 8 : 2, head: indent + 18, firstLine: indent + 4, tabs: [indent + 18])
                    append([.text(marker + "\t")] + item.inlines, font: Fonts.body, paragraph: paragraph)
                }
            case .code(_, let text):
                let block = NSTextBlock()
                block.backgroundColor = Colors.codeBackground
                for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] { block.setWidth(edge == .minX || edge == .maxX ? 8 : 5, type: .absoluteValueType, for: .padding, edge: edge) }
                let lines = text.isEmpty ? [" "] : text.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let paragraph = style(after: index == lines.count - 1 ? 8 : 0, lineHeight: 1.25)
                    paragraph.textBlocks = [block]
                    paragraph.lineBreakMode = .byCharWrapping
                    append([.text(line.isEmpty ? " " : line)], font: Fonts.code, paragraph: paragraph)
                }
            case .table(let header, let rows):
                guard !header.isEmpty else { continue }
                let table = NSTextTable()
                table.numberOfColumns = header.count
                table.collapsesBorders = true
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                let all = [header] + rows
                for (rowIndex, row) in all.enumerated() {
                    for column in 0..<header.count {
                        let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(Colors.rule)
                        cell.setWidth(5, type: .absoluteValueType, for: .padding)
                        if rowIndex == 0 { cell.backgroundColor = Colors.headerBackground }
                        let paragraph = style(after: rowIndex == all.count - 1 ? 10 : 0, lineHeight: 1.15)
                        paragraph.textBlocks = [cell]
                        let inlines = column < row.count ? row[column] : []
                        let font = rowIndex == 0 ? NSFont.systemFont(ofSize: 9.5, weight: .semibold) : NSFont.systemFont(ofSize: 9.5)
                        append(inlines.isEmpty ? [.text(" ")] : inlines, font: font, paragraph: paragraph)
                    }
                }
            case .rule:
                let block = NSTextBlock()
                block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(Colors.rule)
                let paragraph = style(before: 2, after: 10, lineHeight: 0.4)
                paragraph.textBlocks = [block]
                append([.text(" ")], font: NSFont.systemFont(ofSize: 4), paragraph: paragraph)
            }
        }
        return result
    }

    // MARK: - HTML

    public static func html(_ document: MarkdownDocument, title: String?) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func render(_ inlines: [MarkdownDocument.Inline]) -> String {
            inlines.map { inline in
                switch inline {
                case .text(let text): escape(text)
                case .bold(let text): "<strong>\(escape(text))</strong>"
                case .italic(let text): "<em>\(escape(text))</em>"
                case .code(let text): "<code>\(escape(text))</code>"
                case .link(let text, let url): "<a href=\"\(escape(url))\">\(escape(text))</a>"
                }
            }.joined()
        }
        var body = ""
        if let title, !title.isEmpty { body += "<h1 class=\"title\">\(escape(title))</h1>\n<p class=\"date\">\(escape(Date.now.formatted(date: .long, time: .omitted)))</p>\n" }
        for block in document.blocks {
            switch block {
            case .heading(let level, let inlines): body += "<h\(level)>\(render(inlines))</h\(level)>\n"
            case .paragraph(let inlines): body += "<p>\(render(inlines))</p>\n"
            case .quote(let inlines): body += "<blockquote><p>\(render(inlines))</p></blockquote>\n"
            case .code(let language, let text):
                body += "<pre><code\(language.map { " class=\"language-\(escape($0))\"" } ?? "")>\(escape(text))</code></pre>\n"
            case .rule: body += "<hr>\n"
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                var depth = -1
                for item in items {
                    while depth < item.level { body += "<\(tag)>\n"; depth += 1 }
                    while depth > item.level { body += "</\(tag)>\n"; depth -= 1 }
                    body += "<li>\(render(item.inlines))</li>\n"
                }
                while depth >= 0 { body += "</\(tag)>\n"; depth -= 1 }
            case .table(let header, let rows):
                body += "<table>\n<thead><tr>" + header.map { "<th>\(render($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in rows { body += "<tr>" + row.map { "<td>\(render($0))</td>" }.joined() + "</tr>\n" }
                body += "</tbody>\n</table>\n"
            }
        }
        let pageTitle = escape(title ?? document.firstHeading ?? "Document")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(pageTitle)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif; max-width: 760px; margin: 48px auto; padding: 0 20px; color: #1d1d1f; }
        @media (prefers-color-scheme: dark) { body { color: #e6e6e6; background: #1c1c1e; } pre, code { background: #2c2c2e; } th { background: #2c2c2e; } td, th { border-color: #3a3a3c; } blockquote { color: #a1a1a6; border-color: #48484a; } }
        h1, h2, h3 { line-height: 1.2; letter-spacing: -0.01em; }
        h1.title { font-size: 2rem; margin-bottom: 0.2em; }
        p.date { color: #6e6e73; margin-top: 0; }
        pre { background: #f5f5f7; padding: 12px 14px; border-radius: 10px; overflow-x: auto; font-size: 13px; }
        code { font-family: ui-monospace, "SF Mono", Menlo, monospace; background: #f5f5f7; padding: 1px 5px; border-radius: 5px; font-size: 0.92em; }
        pre code { padding: 0; background: none; }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: 14px; }
        th, td { border: 1px solid #d2d2d7; padding: 7px 10px; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; }
        blockquote { border-left: 3px solid #d2d2d7; margin: 1em 0; padding: 2px 14px; color: #6e6e73; }
        hr { border: 0; border-top: 1px solid #d2d2d7; margin: 2em 0; }
        a { color: #0a84ff; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    // MARK: - Word

    public static func docxData(_ document: MarkdownDocument, title: String?) throws -> Data {
        var writer = DocxWriter(document: document, title: title)
        let package = writer.files()
        let workDirectory = FileManager.default.temporaryDirectory.appending(path: "tepfasonic-docx-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        for (path, contents) in package {
            let url = workDirectory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let output = workDirectory.deletingLastPathComponent().appending(path: workDirectory.lastPathComponent + ".docx")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", workDirectory.path, output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.zip(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.zip(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return try Data(contentsOf: output)
    }
}

/// The parts of a .docx package as XML strings.
struct DocxWriter {
    let document: MarkdownDocument
    let title: String?
    private var hyperlinks: [(id: String, url: String)] = []
    private var numberingInstances: [(id: Int, abstract: Int)] = [(1, 0)]

    init(document: MarkdownDocument, title: String?) {
        self.document = document
        self.title = title
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    mutating func files() -> [String: String] {
        let body = documentBody()
        var package: [String: String] = [:]
        package["[Content_Types].xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
        package["_rels/.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
        var relationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        <Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>

        """
        for link in hyperlinks {
            relationships += "<Relationship Id=\"\(link.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(Self.escape(link.url))\" TargetMode=\"External\"/>\n"
        }
        relationships += "</Relationships>\n"
        package["word/_rels/document.xml.rels"] = relationships
        package["word/document.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>
        \(body)<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
        </w:body>
        </w:document>
        """
        package["word/styles.xml"] = Self.styles
        package["word/numbering.xml"] = numbering()
        package["word/footer1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:rPr><w:color w:val="737373"/><w:sz w:val="16"/></w:rPr><w:t xml:space="preserve">\(Self.escape(title ?? ""))\(title == nil ? "" : "  ·  ")Page </w:t></w:r><w:r><w:rPr><w:color w:val="737373"/><w:sz w:val="16"/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:rPr><w:color w:val="737373"/><w:sz w:val="16"/></w:rPr><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:rPr><w:color w:val="737373"/><w:sz w:val="16"/></w:rPr><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:rPr><w:color w:val="737373"/><w:sz w:val="16"/></w:rPr><w:t>1</w:t></w:r><w:r><w:rPr><w:color w:val="737373"/><w:sz w:val="16"/></w:rPr><w:fldChar w:fldCharType="end"/></w:r></w:p>
        </w:ftr>
        """
        let now = ISO8601DateFormatter().string(from: .now)
        package["docProps/core.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(Self.escape(title ?? document.firstHeading ?? "Document"))</dc:title>
        <dc:creator>Tepfasonic</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
        package["docProps/app.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Tepfasonic</Application></Properties>
        """
        return package
    }

    // MARK: Body

    private mutating func documentBody() -> String {
        var xml = ""
        if let title, !title.isEmpty {
            xml += paragraph(style: "Title", runs: runs([.text(title)]))
            xml += paragraph(style: "Subtitle", runs: runs([.text(Date.now.formatted(date: .long, time: .omitted))]))
        }
        for block in document.blocks {
            switch block {
            case .heading(let level, let inlines):
                xml += paragraph(style: "Heading\(min(level, 3))", runs: runs(inlines))
            case .paragraph(let inlines):
                xml += paragraph(style: nil, runs: runs(inlines))
            case .quote(let inlines):
                xml += paragraph(style: "Quote", runs: runs(inlines))
            case .code(_, let text):
                let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
                for line in lines {
                    xml += "<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr>" + run(line, code: true) + "</w:p>\n"
                }
            case .rule:
                xml += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"240\"/></w:pPr></w:p>\n"
            case .list(let ordered, let items):
                var numberID = 1
                if ordered {
                    numberID = (numberingInstances.map(\.id).max() ?? 1) + 1
                    numberingInstances.append((numberID, 1))
                }
                for item in items {
                    xml += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(item.level, 2))\"/><w:numId w:val=\"\(numberID)\"/></w:numPr></w:pPr>" + runs(item.inlines) + "</w:p>\n"
                }
            case .table(let header, let rows):
                guard !header.isEmpty else { continue }
                let width = 9026 / header.count
                xml += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
                for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                    xml += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>"
                }
                xml += "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar><w:tblLook w:val=\"04A0\" w:firstRow=\"1\"/></w:tblPr><w:tblGrid>"
                for _ in header { xml += "<w:gridCol w:w=\"\(width)\"/>" }
                xml += "</w:tblGrid>\n"
                for (rowIndex, row) in ([header] + rows).enumerated() {
                    xml += "<w:tr>"
                    if rowIndex == 0 { xml += "<w:trPr><w:tblHeader/></w:trPr>" }
                    for column in 0..<header.count {
                        let inlines = column < row.count ? row[column] : []
                        xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                        if rowIndex == 0 { xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" }
                        xml += "</w:tcPr><w:p><w:pPr><w:spacing w:before=\"40\" w:after=\"40\"/></w:pPr>"
                        xml += rowIndex == 0 ? runs(inlines.map { inline in if case .text(let s) = inline { return .bold(s) } else { return inline } }) : runs(inlines)
                        xml += "</w:p></w:tc>"
                    }
                    xml += "</w:tr>\n"
                }
                xml += "</w:tbl>\n<w:p/>\n"
            }
        }
        if xml.isEmpty { xml = "<w:p/>\n" }
        return xml
    }

    private func paragraph(style: String?, runs: String) -> String {
        let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(properties)\(runs)</w:p>\n"
    }

    private mutating func runs(_ inlines: [MarkdownDocument.Inline]) -> String {
        var xml = ""
        for inline in inlines {
            switch inline {
            case .text(let text): xml += run(text)
            case .bold(let text): xml += run(text, bold: true)
            case .italic(let text): xml += run(text, italic: true)
            case .code(let text): xml += run(text, code: true)
            case .link(let text, let url):
                let id = "rIdLink\(hyperlinks.count + 1)"
                hyperlinks.append((id, url))
                xml += "<w:hyperlink r:id=\"\(id)\"><w:r><w:rPr><w:rStyle w:val=\"Hyperlink\"/></w:rPr><w:t xml:space=\"preserve\">\(Self.escape(text))</w:t></w:r></w:hyperlink>"
            }
        }
        return xml
    }

    private func run(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) -> String {
        var properties = ""
        if bold { properties += "<w:b/>" }
        if italic { properties += "<w:i/>" }
        if code { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/><w:sz w:val=\"18\"/>" }
        if code && !bold && !italic { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" }
        let wrapped = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(wrapped)<w:t xml:space=\"preserve\">\(Self.escape(text))</w:t></w:r>"
    }

    private func numbering() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>

        """
        for (level, marker) in ["•", "◦", "▪"].enumerated() {
            xml += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(marker)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + 360 * level)\" w:hanging=\"360\"/></w:pPr></w:lvl>\n"
        }
        xml += "</w:abstractNum>\n<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\n"
        for (level, format) in ["decimal", "lowerLetter", "lowerRoman"].enumerated() {
            xml += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + 360 * level)\" w:hanging=\"360\"/></w:pPr></w:lvl>\n"
        }
        xml += "</w:abstractNum>\n"
        for instance in numberingInstances {
            xml += "<w:num w:numId=\"\(instance.id)\"><w:abstractNumId w:val=\"\(instance.abstract)\"/>"
            if instance.abstract == 1 { xml += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" }
            xml += "</w:num>\n"
        }
        xml += "</w:numbering>\n"
        return xml
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi" w:eastAsiaTheme="minorHAnsi" w:cstheme="minorBidi"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-GB"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="52"/><w:szCs w:val="52"/><w:color w:val="1D1D1F"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="360"/></w:pPr><w:rPr><w:color w:val="6E6E73"/><w:sz w:val="20"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="34"/><w:szCs w:val="34"/><w:color w:val="1D1D1F"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/><w:color w:val="1D1D1F"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="220" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/><w:color w:val="1D1D1F"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="12" w:color="D2D2D7"/></w:pBdr><w:ind w:left="480"/></w:pPr><w:rPr><w:i/><w:color w:val="6E6E73"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F5F5F7"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="200" w:right="200"/><w:contextualSpacing/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0A84FF"/><w:u w:val="single"/></w:rPr></w:style>
    <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/></w:tblBorders></w:tblPr></w:style>
    </w:styles>
    """
}
