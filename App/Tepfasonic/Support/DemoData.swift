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

        let group = HostGroup(name: "Lab", sortOrder: 0, colorLabel: "#5E9CFF")
        context.insert(group)
        let productionGroup = HostGroup(name: "Production", sortOrder: 1, colorLabel: "#FF5F57")
        context.insert(productionGroup)
        context.insert(HostGroup(name: "Staging", sortOrder: 2))

        do {
            let pair = try SSHKeyPair.generate(.ed25519, comment: "demo@tepfasonic")
            let key = try IdentityOperations.createKeychainIdentity(name: "Demo Ed25519", username: "deploy", pair: pair, in: context)
            let admin = try IdentityOperations.createPasswordIdentity(name: "Lab admin", username: "admin", password: "demo-password", in: context)
            let bastion = SSHHost(name: "bastion", hostname: "bastion.example.org", username: "jump", authMethod: .privateKey, tags: ["jump"], colorLabel: "#FF9F0A", identity: key)
            context.insert(bastion)
            let buildBox = SSHHost(name: "build-box", hostname: "10.0.0.5", username: "ubuntu", authMethod: .privateKey, tags: ["ci"], colorLabel: "#34C759", group: group, identity: key)
            buildBox.jumpHost = bastion
            buildBox.themeID = "builtin:nord"
            context.insert(buildBox)
            context.insert(SSHHost(name: "router", hostname: "192.168.1.1", username: "admin", authMethod: .privateKey, sortOrder: 1, group: group, identity: admin))
            context.insert(SSHHost(name: "web-01", hostname: "web-01.example.org", username: "deploy", authMethod: .privateKey, tags: ["web"], sortOrder: 0, group: productionGroup, identity: key))
            context.insert(SSHHost(name: "db-01", hostname: "10.1.0.12", username: "deploy", authMethod: .privateKey, tags: ["db"], sortOrder: 1, group: productionGroup, identity: key))
            let production = SSHHost(name: "example.org", hostname: "example.org", username: "me", authMethod: .password)
            production.backgroundTint = "#FF5F57"
            production.watermark = "PROD"
            production.agentPermission = .readOnly
            context.insert(production)
            context.insert(PortForwardRule(name: "Postgres on build-box", kind: .local, bindPort: 15432, targetHost: "localhost", targetPort: 5432, autoStart: true, host: buildBox))
            context.insert(PortForwardRule(name: "Browser via bastion", kind: .dynamic, bindPort: 1080, host: bastion))
            context.insert(PortForwardRule(name: "Expose dev server", kind: .remote, bindAddress: "0.0.0.0", bindPort: 8080, targetHost: "localhost", targetPort: 3000, host: production))
            group.defaultJumpHost = bastion
            group.themeID = "builtin:gruvbox-dark"
        } catch {
            print("DemoData: \(error)")
        }

        context.insert(SerialProfile(name: "Lab switch", devicePath: "/dev/cu.usbserial-1420", baudRate: 9600, colorLabel: "#BF5AF2"))
        if let scheme = try? TerminalTheme.bundled(id: "builtin:dracula")?.asUserTheme(named: "Dracula (mine)").encodedJSON() {
            context.insert(TerminalThemeRecord(name: "Dracula (mine)", schemeJSON: scheme, source: "editor"))
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
            // TEPFA_TEST_SSH_NAME names it (screenshots show "ci-runner" rather than "local sshd");
            // TEPFA_TEST_SSH_HOSTKEY (path to the sshd's public host key) trusts it ahead of time.
            let hostname = env["TEPFA_TEST_SSH_HOST"] ?? "127.0.0.1"
            let local = SSHHost(name: env["TEPFA_TEST_SSH_NAME"] ?? "local sshd", hostname: hostname, port: port, username: NSUserName(), authMethod: .privateKey, tags: ["test"], sortOrder: 2, colorLabel: "#34C759", group: env["TEPFA_TEST_SSH_NAME"] == nil ? nil : group, identity: identity)
            local.defaultSnippet = diskUsage
            local.inheritsGroupJumpHost = false   // reachable directly, whatever the group's bastion
            context.insert(local)
            if let hostKeyPath = env["TEPFA_TEST_SSH_HOSTKEY"],
               let line = try? String(contentsOfFile: hostKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let fingerprint = HostKeyFingerprint.sha256(openSSHPublicKey: line) {
                let keyType = String(line.split(separator: " ").first ?? "ssh-ed25519")
                Task { try? await KnownHostsStore.shared.remember(host: hostname, port: port, keyType: keyType, publicKey: line, fingerprintSHA256: fingerprint) }
            }
        }
        try? context.save()
    }
}
#endif
