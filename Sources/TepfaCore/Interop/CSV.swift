import Foundation

/// A small RFC 4180 reader: quotes, escaped quotes, embedded newlines, CRLF.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        // Scalars, not Characters: "\r\n" is a single Character and would hide the line break.
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let scalar = next() {
            let character = Character(scalar)
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                if let following = next(), following != "\n" { pending = following }
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            case "\n":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}
