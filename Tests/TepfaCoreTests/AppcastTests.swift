import Foundation
import Testing
@testable import TepfaCore

@Suite struct AppcastTests {
    static let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Tepfasonic</title>
        <item>
          <title>Version 0.2.0</title>
          <pubDate>Tue, 10 Nov 2026 09:00:00 +0000</pubDate>
          <sparkle:version>12</sparkle:version>
          <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
          <description><![CDATA[<h2>New</h2><ul><li>Tabs</li></ul>]]></description>
          <enclosure url="https://github.com/Edwardrem/Tepfasonic-Client/releases/download/v0.2.0/Tepfasonic-0.2.0.zip" length="100" type="application/octet-stream" sparkle:edSignature="abc" />
        </item>
        <item>
          <title>Version 0.3.0 beta 1</title>
          <sparkle:channel>beta</sparkle:channel>
          <sparkle:releaseNotesLink>https://edwardrem.github.io/Tepfasonic-Client/notes/0.3.0b1.html</sparkle:releaseNotesLink>
          <enclosure url="https://example.com/beta.zip" sparkle:version="13" sparkle:shortVersionString="0.3.0b1" />
        </item>
        <item>
          <title>Version 0.1.0</title>
          <enclosure url="https://example.com/old.zip" sparkle:version="3" sparkle:shortVersionString="0.1.0" />
        </item>
      </channel>
    </rss>
    """

    @Test func parsesItemsAndEnclosureAttributes() throws {
        let appcast = try Appcast.parse(Data(Self.feed.utf8))
        #expect(appcast.items.count == 3)
        let stable = try #require(appcast.items.first { $0.version == "12" })
        #expect(stable.shortVersion == "0.2.0")
        #expect(stable.channel == nil)
        #expect(stable.minimumSystemVersion == "15.0")
        #expect(stable.releaseNotesHTML?.contains("<li>Tabs</li>") == true)
        #expect(stable.downloadURL?.lastPathComponent == "Tepfasonic-0.2.0.zip")
        #expect(stable.publishedAt != nil)
        let beta = try #require(appcast.items.first { $0.version == "13" })
        #expect(beta.channel == "beta")
        #expect(beta.shortVersion == "0.3.0b1")
        #expect(beta.releaseNotesURL?.host == "edwardrem.github.io")
    }

    @Test func picksNewestAllowedUpdate() throws {
        let appcast = try Appcast.parse(Data(Self.feed.utf8))
        #expect(appcast.newestUpdate(after: "3")?.version == "12")
        #expect(appcast.newestUpdate(after: "12") == nil)
        #expect(appcast.newestUpdate(after: "12", allowedChannels: ["beta"])?.version == "13")
        #expect(appcast.newestUpdate(after: "20", allowedChannels: ["beta"]) == nil)
    }

    @Test func versionComparison() {
        #expect(Appcast.compareVersions("1.2.10", "1.2.9") == .orderedDescending)
        #expect(Appcast.compareVersions("1.2", "1.2.0") == .orderedSame)
        #expect(Appcast.compareVersions("0.9", "1.0") == .orderedAscending)
    }

    /// The feed `Scripts/appcast_item.py` writes when no Sparkle key is configured.
    static let unsignedFeed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Tepfasonic</title>
        <link>https://edwardrem.github.io/Tepfasonic-Client/</link>
        <description>Tepfasonic releases</description>
        <language>en</language>
        <item>
          <title>Tepfasonic 0.3.3</title>
          <link>https://github.com/Edwardrem/Tepfasonic-Client/releases/tag/v0.3.3</link>
          <sparkle:version>7</sparkle:version>
          <sparkle:shortVersionString>0.3.3</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
          <sparkle:releaseNotesLink>https://github.com/Edwardrem/Tepfasonic-Client/releases/tag/v0.3.3</sparkle:releaseNotesLink>
          <pubDate>Tue, 11 Nov 2026 12:00:00 GMT</pubDate>
          <enclosure url="https://github.com/Edwardrem/Tepfasonic-Client/releases/download/v0.3.3/Tepfasonic-0.3.3.dmg" length="14836175" type="application/octet-stream" sparkle:version="7" sparkle:shortVersionString="0.3.3"/>
        </item>
      </channel>
    </rss>
    """

    @Test func readsTheUnsignedWorkflowFeed() throws {
        let appcast = try Appcast.parse(Data(Self.unsignedFeed.utf8))
        let item = try #require(appcast.newestUpdate(after: "5"))
        #expect(item.version == "7")
        #expect(item.shortVersion == "0.3.3")
        #expect(item.channel == nil)
        #expect(item.downloadURL?.lastPathComponent == "Tepfasonic-0.3.3.dmg")
        #expect(item.releaseNotesURL?.path.hasSuffix("/v0.3.3") == true)
        #expect(item.publishedAt != nil)
        #expect(appcast.newestUpdate(after: "7") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: AppcastError.self) { try Appcast.parse(Data("<rss><channel><item>".utf8)) }
    }
}
