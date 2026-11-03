#if DEBUG
import Foundation
import SwiftData
import TepfaCore
import TepfaSSH

/// Sample records for screenshots and manual QA. Debug builds only, and only
/// when launched with `--seed-demo` against an empty store (pair it with
/// `TEPFA_DATA_DIR` and `TEPFA_KEYCHAIN_SERVICE` to keep real data untouched).
@MainActor
enum DemoData {
    static func seedIfEmpty(in context: ModelContext) {
        let hostCount = (try? context.fetchCount(FetchDescriptor<SSHHost>())) ?? 0
        let identityCount = (try? context.fetchCount(FetchDescriptor<Identity>())) ?? 0
        guard hostCount == 0, identityCount == 0 else { return }

        let group = HostGroup(name: "Lab", colorLabel: "#5E9CFF")
        context.insert(group)

        do {
            let pair = try SSHKeyPair.generate(.ed25519, comment: "demo@tepfasonic")
            let key = try IdentityOperations.createKeychainIdentity(name: "Demo Ed25519", username: "deploy", pair: pair, in: context)
            let admin = try IdentityOperations.createPasswordIdentity(name: "Lab admin", username: "admin", password: "demo-password", in: context)
            context.insert(SSHHost(name: "build-box", hostname: "10.0.0.5", username: "ubuntu", authMethod: .privateKey, tags: ["ci"], colorLabel: "#34C759", group: group, identity: key))
            context.insert(SSHHost(name: "router", hostname: "192.168.1.1", username: "admin", authMethod: .privateKey, group: group, identity: admin))
            context.insert(SSHHost(name: "example.org", hostname: "example.org", username: "me", authMethod: .password))
        } catch {
            print("DemoData: \(error)")
        }

        let ops = SnippetFolder(name: "Ops", sortOrder: 0)
        context.insert(ops)
        let diskUsage = Snippet(name: "Disk usage", command: "df -h", tags: ["disk"], sortOrder: 0, folder: ops)
        context.insert(diskUsage)
        context.insert(Snippet(name: "Tail a log", command: "tail -n {{lines:100}} -f {{file:/var/log/syslog}}", tags: ["logs"], sortOrder: 1, folder: ops))
        context.insert(Snippet(name: "Who is logged in", command: "who", sortOrder: 2))
        context.insert(Snippet(name: "Update packages", command: "sudo apt update && sudo apt upgrade -y", tags: ["apt"], notes: "Debian and Ubuntu only.", sortOrder: 3))

        // A host for the throwaway sshd from Scripts/test-sshd.sh, when its environment is present.
        let env = ProcessInfo.processInfo.environment
        if let port = env["TEPFA_TEST_SSH_PORT"].flatMap(Int.init), let keyPath = env["TEPFA_TEST_SSH_KEY"] {
            let identity = Identity(name: "Test sshd key", username: NSUserName(), credentialKind: .keyFile, privateKeyPath: keyPath)
            context.insert(identity)
            let local = SSHHost(name: "local sshd", hostname: env["TEPFA_TEST_SSH_HOST"] ?? "127.0.0.1", port: port, username: NSUserName(), authMethod: .privateKey, tags: ["test"], colorLabel: "#FF9F0A", identity: identity)
            local.defaultSnippet = diskUsage
            context.insert(local)
        }
        try? context.save()
    }
}
#endif
