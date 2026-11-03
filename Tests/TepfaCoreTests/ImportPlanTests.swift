import Foundation
import SwiftData
import Testing
@testable import TepfaCore

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(TepfaSchema.models)
    return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
}

private func temporaryKnownHosts() -> KnownHostsStore {
    KnownHostsStore(url: FileManager.default.temporaryDirectory.appending(path: "tepfa-import-\(UUID().uuidString)/known_hosts.json"))
}

@Suite @MainActor struct ExportImportTests {
    @Test func exportThenImportIsIdentical() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let group = HostGroup(name: "Lab", colorLabel: "#5E9CFF")
        context.insert(group)
        let identity = Identity(name: "deploy", username: "deploy", credentialKind: .keychainKey, keyType: "ssh-ed25519", fingerprint: "SHA256:abc")
        context.insert(identity)
        let folder = SnippetFolder(name: "Ops")
        context.insert(folder)
        let snippet = Snippet(name: "disk", command: "df -h", tags: ["disk"], folder: folder)
        context.insert(snippet)
        let host = SSHHost(name: "box", hostname: "10.0.0.5", username: "ubuntu", authMethod: .privateKey, tags: ["ci"], group: group, identity: identity)
        host.defaultSnippet = snippet
        context.insert(host)
        try context.save()
        let known = [KnownHostEntry(host: "10.0.0.5", port: 22, keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAA", fingerprintSHA256: "SHA256:k")]

        let document = try await ExportBuilder.document(from: context, knownHosts: known, options: .init(), appVersion: "0.1")
        #expect(document.hosts.count == 1)
        #expect(document.hosts[0].groupID == group.uuid)
        #expect(document.hosts[0].identityID == identity.uuid)
        #expect(document.hosts[0].defaultSnippetID == snippet.uuid)
        #expect(document.snippets[0].folderID == folder.uuid)
        #expect(document.secrets == nil)

        let plan = try ImportPlan(document: document, context: context, knownHosts: known)
        #expect(plan.items.count == 6)
        #expect(plan.items.allSatisfy { $0.status == .identical && $0.action == .skip })
        #expect(plan.importedCount == 0)
    }

    @Test func changedAndNewRecordsAreDetectedAndApplied() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let host = SSHHost(name: "box", hostname: "10.0.0.5", username: "ubuntu")
        context.insert(host)
        try context.save()

        var document = TepfaDocument()
        let groupID = UUID()
        let identityID = UUID()
        document.groups = [.init(id: groupID, name: "Prod")]
        document.identities = [.init(id: identityID, name: "ops", username: "ops", credentialKind: "keyFile", privateKeyPath: "/nonexistent/id_ed25519")]
        document.hosts = [
            .init(id: host.uuid, name: "box renamed", hostname: "10.0.0.5", port: 2200, username: "ubuntu", groupID: groupID),
            .init(id: UUID(), name: "new", hostname: "new.example", username: "me", authMethod: "privateKey", identityID: identityID),
        ]
        document.knownHosts = [.init(host: "new.example", port: 22, keyType: "ssh-ed25519", publicKey: "ssh-ed25519 BBBB", fingerprintSHA256: "SHA256:n")]
        document.secrets = .init(identities: [identityID.uuidString: .init(privateKey: "KEYTEXT", passphrase: "pp")])

        var plan = try ImportPlan(document: document, context: context, knownHosts: [])
        #expect(plan.count(.new) == 4)
        #expect(plan.count(.changed) == 1)
        let changed = try #require(plan.items.first { $0.status == .changed })
        #expect(changed.changes == ["groupID", "name", "port"])
        #expect(changed.action == .replace)

        var stored: [(String, TepfaDocument.IdentitySecrets)] = []
        let knownHosts = temporaryKnownHosts()
        let result = try await plan.apply(to: context, knownHosts: knownHosts) { identity, secrets in
            stored.append((identity.name, secrets))
        }
        #expect(result.added == 4)
        #expect(result.replaced == 1)
        #expect(result.keysMovedToKeychain == 1)
        #expect(result.knownHostsAdded == 1)
        #expect(stored.count == 1)
        #expect(stored[0].1.privateKey == "KEYTEXT")
        #expect(stored[0].1.passphrase == nil) // a key moved into the Keychain is stored unencrypted

        let hosts = try context.fetch(FetchDescriptor<SSHHost>(sortBy: [SortDescriptor(\.name)]))
        #expect(hosts.map(\.name) == ["box renamed", "new"])
        #expect(hosts[0].port == 2200)
        #expect(hosts[0].group?.name == "Prod")
        #expect(hosts[1].identity?.name == "ops")
        #expect(hosts[1].identity?.credentialKind == .keychainKey)
        #expect(await knownHosts.verdict(host: "new.example", port: 22, keyType: "ssh-ed25519", publicKey: "ssh-ed25519 BBBB") == .known)

        // Importing the same document again finds nothing to do, except the
        // identity whose key moved into the Keychain (its kind and path changed).
        let again = try ImportPlan(document: document, context: context, knownHosts: await knownHosts.allEntries())
        #expect(again.items.filter { $0.status != .identical }.map(\.kind) == [.identity])
        #expect(again.items.first { $0.kind == .identity }?.changes == ["credentialKind", "privateKeyPath"])

        // Skipping a changed record leaves it alone.
        plan.setImported(false, status: .changed)
        #expect(plan.items.first { $0.status == .changed }?.action == .skip)
    }

    @Test func hostsWhoseIdentityIsSkippedFallBackToPassword() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var document = TepfaDocument()
        let identityID = UUID()
        document.identities = [.init(id: identityID, name: "ops", credentialKind: "keychainKey")]
        document.hosts = [.init(id: UUID(), name: "h", hostname: "h", username: "u", authMethod: "privateKey", identityID: identityID)]
        var plan = try ImportPlan(document: document, context: context, knownHosts: [])
        plan.setAction(.skip, for: "identity:\(identityID.uuidString)")
        _ = try await plan.apply(to: context, knownHosts: nil)
        let host = try #require(try context.fetch(FetchDescriptor<SSHHost>()).first)
        #expect(host.identity == nil)
        #expect(host.authMethod == .password)
    }
}
