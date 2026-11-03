import Foundation
import SwiftData
import Testing
import TepfaCore
@testable import TepfaTerminal

@Suite @MainActor struct HostDescriptorChainTests {
    /// The container must outlive the context, so callers keep it.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(TepfaSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func jumpChainIsOrderedOutermostFirstAndCyclesAreBroken() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let outer = SSHHost(name: "outer", hostname: "o", username: "a")
        let inner = SSHHost(name: "inner", hostname: "i", username: "b")
        let target = SSHHost(name: "target", hostname: "t", username: "c")
        context.insert(outer); context.insert(inner); context.insert(target)
        inner.jumpHost = outer
        target.jumpHost = inner
        let descriptor = HostDescriptor(target)
        #expect(descriptor.jumpChain.map(\.name) == ["outer", "inner"])
        #expect(descriptor.jumpChain.allSatisfy { $0.jumpChain.isEmpty })
        #expect(descriptor.routeDescription == "via outer → inner")

        outer.jumpHost = target // cycle
        let cyclic = HostDescriptor(target)
        #expect(cyclic.jumpChain.map(\.name) == ["outer", "inner"])
    }

    @Test func groupDefaultsApplyUnlessOverridden() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let identity = Identity(name: "ops", username: "ops", credentialKind: .keychainKey)
        let bastion = SSHHost(name: "bastion", hostname: "b", username: "j")
        let group = HostGroup(name: "G")
        context.insert(identity); context.insert(bastion); context.insert(group)
        group.defaultIdentity = identity
        group.defaultJumpHost = bastion
        group.themeID = "builtin:nord"
        group.fontName = "Menlo"
        let host = SSHHost(name: "h", hostname: "h", username: "u", authMethod: .password)
        context.insert(host)
        host.group = group

        var descriptor = HostDescriptor(host)
        #expect(descriptor.identity?.name == "ops")
        #expect(descriptor.authMethod == .privateKey)
        #expect(descriptor.loginUsername == "ops")
        #expect(descriptor.jumpChain.map(\.name) == ["bastion"])
        #expect(descriptor.appearance.themeID == "builtin:nord")
        #expect(descriptor.appearance.fontName == "Menlo")

        host.inheritsGroupJumpHost = false
        host.themeID = "builtin:dracula"
        descriptor = HostDescriptor(host)
        #expect(descriptor.jumpChain.isEmpty)
        #expect(descriptor.appearance.themeID == "builtin:dracula")

        // The bastion itself never jumps through itself even as the group default.
        bastion.group = group
        #expect(HostDescriptor(bastion).jumpChain.isEmpty)
    }

    @Test func descriptorsEncodeTheirChainAndSerialSettings() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let profile = SerialProfile(name: "console", devicePath: "/dev/cu.usbserial-1", baudRate: 9600)
        context.insert(profile)
        let serial = HostDescriptor(profile)
        #expect(serial.isSerial)
        #expect(serial.usesIdentity)
        #expect(serial.target == "/dev/cu.usbserial-1 · 9600 8N1")
        let data = try JSONEncoder().encode(serial)
        let decoded = try JSONDecoder().decode(HostDescriptor.self, from: data)
        #expect(decoded == serial)

        let plain = HostDescriptor(name: "x", hostname: "x", username: "u")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("jumpChain"))
        #expect(!json.contains("serial"))
    }
}

@Suite struct HexDumpTests {
    @Test func formatsSixteenBytesPerLine() {
        let text = HexDump.lines(Array("Hello, world!\n\u{1}\u{2}\u{3}".utf8), offset: 16)
        let lines = text.split(separator: "\r\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("00000010  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 01 02  |Hello, world!...|"))
        #expect(lines[1].hasPrefix("00000020  03 "))
        #expect(lines[1].hasSuffix("|.|"))
    }
}
