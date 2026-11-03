import Foundation
import Testing
@testable import TepfaCore

@Suite struct SSHConfigFileTests {
    static let sample = """
    # personal hosts
    Host *
        ServerAliveInterval 30

    Host web web.example.com
        HostName web.example.com
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_web
        IdentityFile ~/.ssh/other

    Host "spaced name"
      HostName 10.0.0.9

    Host bastion
    HostName=bastion.example.com
    ProxyJump jumper

    Match host something
        User nobody

    Host after-match
        HostName after.example.com
    """

    @Test func parsesHostBlocksAndSkipsPatternsAndMatch() {
        let hosts = SSHConfigFile.parse(Self.sample)
        #expect(hosts.map(\.alias) == ["*", "web", "web.example.com", "spaced name", "bastion", "after-match"])
        let web = hosts[1]
        #expect(web.hostName == "web.example.com")
        #expect(web.user == "deploy")
        #expect(web.port == 2222)
        #expect(web.identityFiles == ["~/.ssh/id_web", "~/.ssh/other"])
        #expect(hosts[4].hostName == "bastion.example.com")
        #expect(hosts[4].proxyJump == "jumper")
        #expect(hosts[0].isPattern)
        #expect(!hosts[3].isPattern)
    }

    @Test func expandsIncludes() {
        let text = "Include extra\nHost main\n  HostName main.example"
        let hosts = SSHConfigFile.parse(text, include: { path in path == "extra" ? "Host inc\n  HostName inc.example" : nil })
        #expect(hosts.map(\.alias) == ["inc", "main"])
        #expect(SSHConfigFile.globMatches("*.conf", "a.conf"))
        #expect(!SSHConfigFile.globMatches("*.conf", "a.txt"))
    }

    @Test func documentSharesIdentitiesPerKeyAndIsStable() {
        let hosts = SSHConfigFile.parse(Self.sample)
        let document = SSHConfigFile.document(from: hosts)
        #expect(document.hosts.map(\.name) == ["web", "web.example.com", "spaced name", "bastion", "after-match"])
        #expect(document.identities.count == 1)
        #expect(document.identities[0].privateKeyPath == "~/.ssh/id_web")
        #expect(document.hosts[0].identityID == document.identities[0].id)
        #expect(document.hosts[1].identityID == document.identities[0].id)
        #expect(document.hosts[2].authMethod == "password")
        #expect(document.hosts[3].notes == "ProxyJump jumper")
        #expect(document.hosts[0].id == SSHConfigFile.document(from: hosts).hosts[0].id)
        let reuse = SSHConfigFile.document(from: hosts, existingIdentityIDs: ["~/.ssh/id_web": UUID(uuidString: "11111111-1111-1111-1111-111111111111")!])
        #expect(reuse.identities.isEmpty)
        #expect(reuse.hosts[0].identityID?.uuidString == "11111111-1111-1111-1111-111111111111")
    }

    @Test func managedBlockIsReplacedInPlace() {
        let hosts = [
            SSHConfigFile.ExportableHost(alias: "web", hostname: "web.example.com", port: 2222, user: "deploy", identityFile: "~/.ssh/id_web"),
            SSHConfigFile.ExportableHost(alias: "db", hostname: "db.internal", user: "me"),
        ]
        let block = SSHConfigFile.managedBlock(for: hosts)
        #expect(block.contains("Host web\n    HostName web.example.com\n    Port 2222\n    User deploy\n    IdentityFile ~/.ssh/id_web\n    IdentitiesOnly yes\n"))
        #expect(!block.contains("Port 22\n"))
        let existing = "Host mine\n  HostName mine.example\n\n\(SSHConfigFile.beginMarker)\nHost old\n\(SSHConfigFile.endMarker)\n# trailing\n"
        let updated = SSHConfigFile.replacingManagedBlock(in: existing, with: block)
        #expect(updated.hasPrefix("Host mine\n  HostName mine.example\n\n\(SSHConfigFile.beginMarker)\nHost web"))
        #expect(updated.hasSuffix("\(SSHConfigFile.endMarker)\n# trailing\n"))
        #expect(!updated.contains("Host old"))
        #expect(SSHConfigFile.replacingManagedBlock(in: "Host a\n", with: block) == "Host a\n\n" + block)
        #expect(SSHConfigFile.alias(for: "My Prod Box!", taken: ["My-Prod-Box"]) == "My-Prod-Box-2")
    }
}

@Suite struct TermiusCSVTests {
    @Test func mapsColumnsByHeader() throws {
        let csv = """
        Groups,Label,Tags,Hostname/IP,Protocol,Port,Username
        Work/Prod,"web, primary","prod;eu",web.example.com,ssh,22,deploy
        ,db,,10.0.0.7,ssh,5432,
        ,printer,,10.0.0.8,telnet,23,admin
        """
        let document = try TermiusCSV.document(from: csv)
        #expect(document.hosts.map(\.name) == ["web, primary", "db"])
        #expect(document.hosts[0].tags == ["termius", "prod", "eu"])
        #expect(document.hosts[0].port == 22)
        #expect(document.hosts[0].username == "deploy")
        #expect(document.groups.map(\.name) == ["Prod"])
        #expect(document.hosts[0].groupID == document.groups[0].id)
        #expect(document.hosts[1].port == 5432)
        #expect(document.hosts[1].groupID == nil)
    }

    @Test func rejectsSpreadsheetsWithoutAHostnameColumn() {
        #expect(throws: TermiusCSV.Error.self) { try TermiusCSV.document(from: "a,b\n1,2\n") }
    }

    @Test func csvHandlesQuotesAndCRLF() {
        let rows = CSV.parse("a,\"b,c\",\"say \"\"hi\"\"\"\r\n1,2,3\r\n")
        #expect(rows == [["a", "b,c", "say \"hi\""], ["1", "2", "3"]], "got \(rows)")
    }
}

@Suite struct PuTTYSessionsTests {
    @Test func parsesRegistryExport() {
        let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\Default%20Settings]
        "HostName"=""

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\My%20Server]
        "HostName"="server.example.com"
        "PortNumber"=dword:00000016
        "UserName"="alice"
        "PublicKeyFile"="C:\\\\Users\\\\alice\\\\key.ppk"
        "Protocol"="ssh"

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\serial-thing]
        "HostName"="COM3"
        "Protocol"="serial"
        """
        let sessions = PuTTYSessions.parseRegistryExport(reg)
        #expect(sessions.count == 2)
        #expect(sessions[0] == PuTTYSessions.Session(name: "My Server", hostName: "server.example.com", port: 22, userName: "alice", publicKeyFile: "C:\\Users\\alice\\key.ppk", proto: "ssh"))
        let document = PuTTYSessions.document(from: sessions)
        #expect(document.hosts.count == 1)
        #expect(document.hosts[0].notes == "PuTTY key file: C:\\Users\\alice\\key.ppk")
        #expect(document.hosts[0].authMethod == "password")
        #expect(document.identities.isEmpty)
    }

    @Test func parsesUnixSessionFileAndUTF16Export() {
        let session = PuTTYSessions.parseSessionFile(named: "lab%20box", contents: "HostName=root@10.0.0.3\nPortNumber=2222\nProtocol=ssh\n")
        #expect(session == PuTTYSessions.Session(name: "lab box", hostName: "10.0.0.3", port: 2222, userName: "root", publicKeyFile: nil, proto: "ssh"))
        let text = "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\x]\n\"HostName\"=\"h\"\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        #expect(PuTTYSessions.decodeRegistryExport(data) == text)
    }
}

@Suite struct TabbyConfigTests {
    @Test func parsesProfilesGroupsAndKeys() throws {
        let yaml = """
        version: 3
        profiles:
          - type: ssh
            name: "web (prod)"
            group: g1
            options:
              host: web.example.com
              port: 2222
              user: deploy
              privateKeys:
                - /Users/me/.ssh/id_web
            id: ssh:custom:web
          - type: ssh
            name: plain
            options:
              host: 10.0.0.4
              privateKeys: []
          - type: local
            name: shell
        groups:
          - id: g1
            name: Production
        hotkeys: {}
        """
        let profiles = try TabbyConfig.profiles(from: yaml)
        #expect(profiles.count == 2)
        #expect(profiles[0] == TabbyConfig.Profile(name: "web (prod)", host: "web.example.com", port: 2222, user: "deploy", privateKeys: ["/Users/me/.ssh/id_web"], group: "Production"))
        #expect(profiles[1] == TabbyConfig.Profile(name: "plain", host: "10.0.0.4", port: 22, user: nil, privateKeys: [], group: nil))
        let document = TabbyConfig.document(from: profiles)
        #expect(document.groups.map(\.name) == ["Production"])
        #expect(document.identities.map(\.privateKeyPath) == ["/Users/me/.ssh/id_web"])
        #expect(document.hosts[0].groupID == document.groups[0].id)
        #expect(document.hosts[1].authMethod == "password")
    }

    @Test func miniYAMLHandlesCommentsQuotesAndBlockScalars() throws {
        let node = try MiniYAML.parse("""
        a: 1 # comment
        b: 'it''s'
        c: "x # not a comment"
        d:
        - one
        - two
        e: |
          line1
          line2
        f: ~
        """)
        #expect(node["a"]?.int == 1)
        #expect(node["b"]?.string == "it's")
        #expect(node["c"]?.string == "x # not a comment")
        #expect(node["d"]?.array.compactMap(\.string) == ["one", "two"])
        #expect(node["e"]?.string == "line1\nline2")
        #expect(node["f"]?.string == nil)
    }
}

@Suite struct StableUUIDTests {
    @Test func isDeterministicAndWellFormed() {
        let a = UUID.stable("ssh-config:web")
        #expect(a == UUID.stable("ssh-config:web"))
        #expect(a != UUID.stable("ssh-config:db"))
        let string = a.uuidString
        #expect(string[string.index(string.startIndex, offsetBy: 14)] == "5")
        #expect("89AB".contains(string[string.index(string.startIndex, offsetBy: 19)]))
    }
}
