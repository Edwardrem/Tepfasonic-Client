import Foundation
import NIOCore
import Testing
@testable import TepfaSSH

@Suite struct SOCKS5Tests {
    @Test func connectRequestEncodesDomainsAndAddresses() throws {
        #expect(SOCKS5.connectRequest(host: "example.com", port: 443) == [5, 1, 0, 3, 11] + Array("example.com".utf8) + [1, 0xBB])
        #expect(SOCKS5.connectRequest(host: "10.0.0.5", port: 22) == [5, 1, 0, 1, 10, 0, 0, 5, 0, 22])
        let v6 = SOCKS5.connectRequest(host: "::1", port: 80)
        #expect(v6.count == 4 + 16 + 2)
        #expect(v6[3] == 4)
        #expect(v6.suffix(2) == [0, 80])
    }

    @Test func serverSideParsingRoundTrips() throws {
        let greeting = SOCKS5.clientGreeting(offersPassword: true)
        let parsed = try #require(try SOCKS5.parseGreeting(greeting))
        #expect(parsed.methods == [0, 2])
        #expect(parsed.length == 4)
        #expect(try SOCKS5.parseGreeting([5]) == nil)

        let request = try #require(try SOCKS5.parseRequest(SOCKS5.connectRequest(host: "db.internal", port: 5432) + [9, 9]))
        #expect(request.command == 1)
        #expect(request.address == .domain("db.internal"))
        #expect(request.address.hostString == "db.internal")
        #expect(request.port == 5432)
        #expect(request.length == 4 + 1 + 11 + 2)

        let partial = Array(SOCKS5.connectRequest(host: "db.internal", port: 5432).dropLast(3))
        #expect(try SOCKS5.parseRequest(partial) == nil)
        #expect(throws: SOCKS5.ParseError.badVersion(4)) { try SOCKS5.parseRequest([4, 1, 0, 1, 1, 2, 3, 4, 0, 80]) }
        #expect(throws: SOCKS5.ParseError.badAddressType(9)) { try SOCKS5.parseRequest([5, 1, 0, 9, 0, 0]) }
    }

    @Test func replyParsingAndDescriptions() throws {
        let ok = SOCKS5.reply(code: 0, boundHost: "0.0.0.0", boundPort: 0)
        let reply = try #require(try SOCKS5.parseReply(ok))
        #expect(reply.code == 0)
        #expect(reply.length == 10)
        #expect(try SOCKS5.parseReply(Array(ok.prefix(5))) == nil)
        #expect(SOCKS5.replyDescription(5) == "connection refused")
        let v4 = try #require(try SOCKS5.parseRequest([5, 1, 0, 1, 192, 168, 1, 1, 0x1F, 0x90]))
        #expect(v4.address.hostString == "192.168.1.1")
        #expect(v4.port == 8080)
    }

    @Test func passwordAuthenticationIsRFC1929() {
        #expect(SOCKS5.passwordAuthentication(username: "ab", password: "c") == [1, 2, 0x61, 0x62, 1, 0x63])
    }
}

@Suite struct HTTPConnectTests {
    @Test func requestCarriesHostAndBasicAuthorization() {
        let request = HTTPConnectHandler.request(host: "example.com", port: 22, credentials: ("u", "p"))
        #expect(request.hasPrefix("CONNECT example.com:22 HTTP/1.1\r\n"))
        #expect(request.contains("Host: example.com:22\r\n"))
        #expect(request.contains("Proxy-Authorization: Basic dTpw\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
        #expect(HTTPConnectHandler.request(host: "::1", port: 22, credentials: nil).hasPrefix("CONNECT [::1]:22 "))
    }

    private func failure(_ header: String) -> ProxyError? {
        if case .failure(let error) = HTTPConnectHandler.parseStatus(header) { return error }
        return nil
    }

    @Test func statusLinesAreClassified() {
        #expect(failure("HTTP/1.1 200 Connection established\r\n") == nil)
        #expect(failure("HTTP/1.0 407 Proxy Authentication Required") == .authenticationRequired)
        #expect(failure("HTTP/1.1 403 Forbidden") == .httpRefused(403, "Forbidden"))
        #expect(failure("garbage") == .malformedReply)
    }

    @Test func headerEndIsFound() {
        var buffer = ByteBuffer()
        buffer.writeString("HTTP/1.1 200 OK\r\nX: y\r\n\r\nSSH-2.0")
        #expect(HTTPConnectHandler.headerEnd(in: buffer) == 21)
        var partial = ByteBuffer()
        partial.writeString("HTTP/1.1 200 OK\r\n")
        #expect(HTTPConnectHandler.headerEnd(in: partial) == nil)
    }
}

@Suite struct SFTPCodecTests {
    @Test func framerSplitsPacketsAcrossReads() {
        var framer = SFTPFramer()
        let packetA: [UInt8] = [0, 0, 0, 3, 101, 0, 1]
        let packetB: [UInt8] = [0, 0, 0, 2, 102, 9]
        #expect(framer.feed(Array(packetA.prefix(5))).isEmpty)
        let first = framer.feed(Array(packetA.dropFirst(5)) + Array(packetB.prefix(3)))
        #expect(first == [[101, 0, 1]])
        #expect(framer.feed(Array(packetB.dropFirst(3))) == [[102, 9]])
    }

    @Test func attributesRoundTrip() throws {
        let attributes = SFTP.Attributes(size: 1234, uid: 1000, gid: 1000, permissions: 0o100644, accessTime: Date(timeIntervalSince1970: 1_700_000_000), modificationTime: Date(timeIntervalSince1970: 1_700_000_100))
        var writer = SFTPWriter()
        attributes.encode(into: &writer)
        var reader = SFTPReader(writer.bytes)
        let decoded = try SFTP.Attributes.decode(from: &reader)
        #expect(decoded == attributes)
        #expect(decoded.kind == .regular)
        #expect(decoded.mode == 0o644)
        #expect(decoded.modeString == "-rw-r--r--")
        #expect(SFTP.Attributes(permissions: 0o040755).modeString == "drwxr-xr-x")
        #expect(SFTP.Attributes(permissions: 0o120777).isSymlink)
        #expect(reader.remaining == 0)
    }

    @Test func framedPacketsHaveLengthPrefix() {
        var writer = SFTPWriter()
        writer.writeUInt8(1)
        writer.writeUInt32(3)
        #expect(writer.framed() == [0, 0, 0, 5, 1, 0, 0, 0, 3])
        var string = SFTPWriter()
        string.writeString("hi")
        #expect(string.bytes == [0, 0, 0, 2, 0x68, 0x69])
    }

    @Test func pathHelpers() {
        #expect(SFTP.join("/home/me", "docs") == "/home/me/docs")
        #expect(SFTP.join("/home/me/", "../other") == "/home/other")
        #expect(SFTP.join("/home/me", "/etc") == "/etc")
        #expect(SFTP.normalize("/a/./b/../c/") == "/a/c")
        #expect(SFTP.parent("/a/b") == "/a")
        #expect(SFTP.parent("/a") == "/")
        #expect(SFTP.parent("/") == "/")
        #expect(SFTP.baseName("/a/b.txt") == "b.txt")
    }

    @Test func entryOwnerFromLongName() {
        let entry = SFTP.Entry(name: "x", longName: "-rw-r--r--    1 alice    staff        12 Nov  3 10:00 x", attributes: SFTP.Attributes())
        #expect(entry.ownerAndGroup?.0 == "alice")
        #expect(entry.ownerAndGroup?.1 == "staff")
    }
}
