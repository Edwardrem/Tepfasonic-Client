import Foundation

/// Incremental Server-Sent Events parser.
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public var name: String?
        public var data: String
    }

    private var pendingLine = ""
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds text and returns the events completed by it.
    public mutating func feed(_ text: String) -> [Event] {
        var events: [Event] = []
        var buffer = pendingLine + text
        pendingLine = ""
        while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if let event = consume(line: line) { events.append(event) }
        }
        pendingLine = buffer
        return events
    }

    /// Flushes a trailing event that was not followed by a blank line.
    public mutating func finish() -> Event? {
        if !pendingLine.isEmpty {
            let line = pendingLine
            pendingLine = ""
            if let event = consume(line: line) { return event }
        }
        return consume(line: "")
    }

    private mutating func consume(line: String) -> Event? {
        if line.isEmpty {
            guard !dataLines.isEmpty || eventName != nil else { return nil }
            let event = Event(name: eventName, data: dataLines.joined(separator: "\n"))
            eventName = nil
            dataLines = []
            return event
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = rest
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
