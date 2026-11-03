import Foundation

/// A Sparkle appcast (RSS with the `sparkle:` namespace), parsed just enough
/// to offer downloads when the in-app installer cannot run.
public struct Appcast: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var title: String
        /// `CFBundleVersion`, used for ordering.
        public var version: String
        /// `CFBundleShortVersionString`, shown to people.
        public var shortVersion: String
        public var channel: String?
        public var publishedAt: Date?
        public var downloadURL: URL?
        public var releaseNotesURL: URL?
        /// HTML description from the item, when no notes link is given.
        public var releaseNotesHTML: String?
        public var minimumSystemVersion: String?

        public var id: String { version }

        public init(title: String, version: String, shortVersion: String, channel: String? = nil, publishedAt: Date? = nil, downloadURL: URL? = nil, releaseNotesURL: URL? = nil, releaseNotesHTML: String? = nil, minimumSystemVersion: String? = nil) {
            self.title = title
            self.version = version
            self.shortVersion = shortVersion
            self.channel = channel
            self.publishedAt = publishedAt
            self.downloadURL = downloadURL
            self.releaseNotesURL = releaseNotesURL
            self.releaseNotesHTML = releaseNotesHTML
            self.minimumSystemVersion = minimumSystemVersion
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public static func parse(_ data: Data) throws -> Appcast {
        let parser = AppcastParser()
        return try parser.parse(data)
    }

    /// The newest item newer than `currentVersion`, limited to the given channels
    /// (nil channel = the stable feed; items with other channels are ignored).
    public func newestUpdate(after currentVersion: String, allowedChannels: Set<String> = []) -> Item? {
        items
            .filter { $0.channel == nil || allowedChannels.contains($0.channel!) }
            .filter { Self.compareVersions($0.version, currentVersion) == .orderedDescending }
            .max { Self.compareVersions($0.version, $1.version) == .orderedAscending }
    }

    /// Numeric dotted comparison: 1.2.10 > 1.2.9, and 1.2 == 1.2.0.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

public enum AppcastError: Error, LocalizedError, Sendable {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): "The update feed could not be read: \(detail)"
        }
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [Appcast.Item] = []
    private var current: Appcast.Item?
    private var text = ""
    private var failure: String?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    func parse(_ data: Data) throws -> Appcast {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse(), failure == nil else {
            throw AppcastError.malformed(failure ?? parser.parserError?.localizedDescription ?? "invalid XML")
        }
        return Appcast(items: items)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "item":
            current = Appcast.Item(title: "", version: "", shortVersion: "")
        case "enclosure":
            guard current != nil else { return }
            if let url = attributes["url"] { current?.downloadURL = URL(string: url) }
            let sparkleAttributes = attributes.filter { $0.key.hasPrefix("sparkle:") || $0.key == "version" || $0.key == "shortVersionString" }
            for (key, value) in sparkleAttributes {
                switch key.replacingOccurrences(of: "sparkle:", with: "") {
                case "version": current?.version = value
                case "shortVersionString": current?.shortVersion = value
                default: break
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSparkle = namespaceURI?.contains("sparkle") == true
        switch elementName {
        case "item":
            if var item = current {
                if item.shortVersion.isEmpty { item.shortVersion = item.version }
                if !item.version.isEmpty { items.append(item) }
                current = nil
            }
        case "title" where current != nil:
            current?.title = value
        case "pubDate" where current != nil:
            current?.publishedAt = Self.dateFormatter.date(from: value)
        case "description" where current != nil:
            current?.releaseNotesHTML = value
        case "version" where isSparkle && current != nil:
            current?.version = value
        case "shortVersionString" where isSparkle && current != nil:
            current?.shortVersion = value
        case "channel" where isSparkle && current != nil:
            current?.channel = value
        case "releaseNotesLink" where isSparkle && current != nil:
            current?.releaseNotesURL = URL(string: value)
        case "minimumSystemVersion" where isSparkle && current != nil:
            current?.minimumSystemVersion = value
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError.localizedDescription
    }
}
