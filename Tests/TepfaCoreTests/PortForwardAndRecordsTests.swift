import Foundation
import SwiftData
import Testing
@testable import TepfaCore

@Suite struct PortForwardDescriptionTests {
    @Test func parsesSSHStyleSpecs() throws {
        let local = try #require(PortForwardDescription.parse("8080:localhost:80", kind: .local))
        #expect(local.bindAddress == "127.0.0.1")
        #expect(local.bindPort == 8080)
        #expect(local.targetHost == "localhost")
        #expect(local.targetPort == 80)
        let bound = try #require(PortForwardDescription.parse("0.0.0.0:5432:db.internal:5432", kind: .remote))
        #expect(bound.bindAddress == "0.0.0.0")
        #expect(bound.targetHost == "db.internal")
        let dynamic = try #require(PortForwardDescription.parse("1080", kind: .dynamic))
        #expect(dynamic.bindPort == 1080)
        #expect(PortForwardDescription.parse("abc", kind: .local) == nil)
        #expect(PortForwardDescription.parse("99999:x:1", kind: .local) == nil)
    }

    @Test func describesRulesAndNormalisesBindAddresses() {
        #expect(PortForwardDescription.describe(kind: .local, bindAddress: "127.0.0.1", bindPort: 8080, targetHost: "db", targetPort: 5432) == "localhost:8080 → db:5432")
        #expect(PortForwardDescription.describe(kind: .dynamic, bindAddress: "0.0.0.0", bindPort: 1080, targetHost: "", targetPort: 0) == "SOCKS5 on 0.0.0.0:1080")
        let rule = PortForwardDescriptor(kind: .local, bindAddress: "*", bindPort: 1, targetHost: "x", targetPort: 2, hostID: nil)
        #expect(rule.effectiveBindAddress == "0.0.0.0")
        #expect(PortForwardDescriptor(kind: .local, bindAddress: "localhost", bindPort: 1, hostID: nil).effectiveBindAddress == "127.0.0.1")
        #expect(PortForwardDescriptor(kind: .local, bindAddress: "", bindPort: 1, hostID: nil).effectiveBindAddress == "127.0.0.1")
    }
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(TepfaSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
}

@Suite @MainActor struct NewRecordsExportImportTests {
    @Test func rulesThemesSerialAndRoutesRoundTrip() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let identity = Identity(name: "ops", username: "ops", credentialKind: .keychainKey)
        context.insert(identity)
        let bastion = SSHHost(name: "bastion", hostname: "jump.example", username: "jump", authMethod: .privateKey, identity: identity)
        context.insert(bastion)
        let group = HostGroup(name: "Prod", colorLabel: "#FF5F57")
        context.insert(group)
        group.defaultIdentity = identity
        group.defaultJumpHost = bastion
        group.proxyKindRaw = "socks5"
        group.proxyHost = "proxy.example"
        group.proxyPort = 1080
        group.proxyUsername = "pu"
        group.themeID = "builtin:nord"
        let host = SSHHost(name: "web", hostname: "10.0.0.9", username: "", authMethod: .privateKey)
        context.insert(host)
        host.group = group
        host.inheritsGroupProxy = false
        host.themeID = "builtin:dracula"
        host.fontSize = 15
        host.backgroundTint = "#FF5F57"
        host.watermark = "PROD"
        let rule = PortForwardRule(name: "db", kind: .local, bindPort: 15432, targetHost: "localhost", targetPort: 5432, autoStart: true)
        context.insert(rule)
        rule.host = host
        let scheme = TerminalTheme.bundled[2].asUserTheme(named: "Mine")
        let theme = TerminalThemeRecord(uuid: UUID(uuidString: scheme.id)!, name: "Mine", schemeJSON: try scheme.encodedJSON(), source: "editor")
        context.insert(theme)
        context.insert(SerialProfile(name: "switch", devicePath: "/dev/cu.usbserial-1", baudRate: 9600, parity: .even, stopBits: 2, flowControl: .hardware, sendLineEnding: .crlf))
        try context.save()

        #expect(host.effectiveIdentity === identity)
        #expect(host.effectiveJumpHost === bastion)
        #expect(host.effectiveProxy == nil)
        host.inheritsGroupProxy = true
        #expect(host.effectiveProxy?.host == "proxy.example")
        #expect(host.effectiveProxy?.ownerID == group.uuid)

        let document = try await ExportBuilder.document(from: context, knownHosts: [], options: .init(), appVersion: "t", secrets: nil, proxyPassword: { _ in "pw" })
        #expect(document.secrets == nil) // secrets option off
        #expect(document.portForwards.count == 1)
        #expect(document.portForwards[0].hostID == host.uuid)
        #expect(document.portForwards[0].name == "db")
        #expect(document.themes.count == 1)
        #expect(document.themes[0].scheme.name == "Mine")
        #expect(document.serialProfiles.count == 1)
        #expect(document.serialProfiles[0].flowControl == "hardware")
        let groupRecord = try #require(document.groups.first)
        #expect(groupRecord.defaultIdentityID == identity.uuid)
        #expect(groupRecord.defaultJumpHostID == bastion.uuid)
        #expect(groupRecord.proxy?.host == "proxy.example")
        #expect(groupRecord.proxy?.username == "pu")
        let hostRecord = try #require(document.hosts.first { $0.id == host.uuid })
        #expect(hostRecord.themeID == "builtin:dracula")
        #expect(hostRecord.watermark == "PROD")
        #expect(hostRecord.jumpHostID == nil)

        var encrypted = try await ExportBuilder.document(from: context, knownHosts: [], options: .init(secrets: true), secrets: { _ in nil }, proxyPassword: { _ in "pw" })
        #expect(encrypted.secrets?.proxyPasswords[group.uuid.uuidString] == "pw")
        encrypted.secrets = nil

        // Import into a fresh store: everything comes back linked.
        let other = try makeContainer()
        let plan = try ImportPlan(document: document, context: other.mainContext, knownHosts: [])
        #expect(plan.kinds.contains(.portForward))
        #expect(plan.kinds.contains(.theme))
        #expect(plan.kinds.contains(.serialProfile))
        #expect(plan.items.allSatisfy { $0.status == .new })
        var stored: [UUID: String] = [:]
        let result = try await plan.apply(to: other.mainContext, knownHosts: nil, proxyPasswordWriter: { id, password in stored[id] = password })
        #expect(result.added == plan.items.count)
        #expect(stored.isEmpty)
        let importedHost = try #require(try other.mainContext.fetch(FetchDescriptor<SSHHost>(predicate: #Predicate { $0.name == "web" })).first)
        #expect(importedHost.group?.defaultJumpHost?.name == "bastion")
        #expect(importedHost.group?.defaultIdentity?.name == "ops")
        #expect(importedHost.themeID == "builtin:dracula")
        #expect(importedHost.portForwards.count == 1)
        #expect(importedHost.portForwards[0].autoStart)
        #expect(importedHost.effectiveJumpHost?.name == "bastion")
        #expect(importedHost.authMethod == .privateKey)
        let importedTheme = try #require(try other.mainContext.fetch(FetchDescriptor<TerminalThemeRecord>()).first)
        #expect(try TerminalTheme.decode(importedTheme.schemeJSON).ansi == scheme.ansi)
        let serial = try #require(try other.mainContext.fetch(FetchDescriptor<SerialProfile>()).first)
        #expect(serial.parity == .even)
        #expect(serial.sendLineEnding == .crlf)

        // A second import of the same document finds everything identical.
        let again = try ImportPlan(document: document, context: other.mainContext, knownHosts: [])
        #expect(again.items.allSatisfy { $0.status == .identical }, "\(again.items.filter { $0.status != .identical }.map { "\($0.id): \($0.changes)" })")
    }

    @Test func olderFilesWithoutNewFieldsStillDecodeAndImport() throws {
        let json = """
        {"format":"tepfa","schemaVersion":1,"exportedAt":"2026-11-03T10:00:00Z","hosts":[{"id":"\(UUID().uuidString)","name":"old","hostname":"h","port":22,"username":"u","authMethod":"password","tags":[],"notes":"","sortOrder":0,"autoReconnect":true,"shellIntegration":"automatic"}]}
        """
        let document = try TepfaFile.decode(Data(json.utf8), passphrase: nil)
        #expect(document.hosts[0].inheritsGroupJumpHost == nil)
        #expect(document.portForwards.isEmpty)
        #expect(document.serialProfiles.isEmpty)
    }
}
