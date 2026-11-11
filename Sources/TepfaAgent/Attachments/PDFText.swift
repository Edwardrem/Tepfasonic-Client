import Foundation
import PDFKit

/// Text of a PDF for endpoints that cannot take the file itself.
enum PDFText {
    static func extract(from data: Data, maxCharacters: Int = 400_000) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        var text = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let content = page.string else { continue }
            text += "--- page \(index + 1) ---\n" + content + "\n"
            if text.count > maxCharacters { break }
        }
        return text.isEmpty ? nil : String(text.prefix(maxCharacters))
    }

    static func pageCount(of data: Data) -> Int? {
        PDFDocument(data: data)?.pageCount
    }
}
