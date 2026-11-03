import Foundation

/// Rebuilds the command line from keystrokes so suggestions can be offered
/// before the server echoes anything, and so history still works without
/// shell integration. Editing keys the tracker cannot follow (arrows, tab
/// completion, history search) mark the line unreliable until the next Enter.
public struct TypedLineTracker: Sendable, Equatable {
    public private(set) var text = ""
    public private(set) var isReliable = true
    private var pendingUTF8: [UInt8] = []

    public init() {}

    /// What happened on the last control byte.
    public enum Event: Equatable, Sendable {
        case none
        /// Enter on a line that could be followed.
        case submitted(String)
        /// Enter on an unreliable line, or ^C.
        case cancelled
    }

    public mutating func reset() {
        text = ""
        isReliable = true
        pendingUTF8 = []
    }

    /// Feeds bytes sent to the server. Returns `.submitted` on Enter.
    public mutating func consume(_ bytes: ArraySlice<UInt8>) -> Event {
        var event = Event.none
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            switch byte {
            case 0x0d, 0x0a:
                let line = text.trimmingCharacters(in: .whitespaces)
                if isReliable {
                    event = line.isEmpty ? .none : .submitted(line)
                } else {
                    event = .cancelled
                }
                reset()
            case 0x7f, 0x08:
                if !text.isEmpty { text.removeLast() } else { isReliable = false }
            case 0x15: // ^U clears the line
                text = ""
                isReliable = true
            case 0x03: // ^C abandons it
                reset()
                event = .cancelled
            case 0x17: // ^W deletes the previous word
                while let last = text.last, last == " " { text.removeLast() }
                while let last = text.last, last != " " { text.removeLast() }
            case 0x1b: // escape sequences (arrows, alt-keys) cannot be followed
                isReliable = false
                index = bytes.endIndex
                continue
            case 0x09, 0x12, 0x01, 0x05, 0x0b, 0x19, 0x0e, 0x10:
                isReliable = false
            case 0x20...0x7e:
                text.append(Character(UnicodeScalar(byte)))
            case 0x80...:
                pendingUTF8.append(byte)
                if let decoded = String(bytes: pendingUTF8, encoding: .utf8) {
                    text += decoded
                    pendingUTF8 = []
                }
            default:
                break
            }
            index += 1
        }
        return event
    }
}
