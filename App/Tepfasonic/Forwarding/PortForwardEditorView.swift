import SwiftData
import SwiftUI
import TepfaCore

/// Creates or edits a forwarding rule.
struct PortForwardEditorView: View {
    let target: AppState.PortForwardEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SSHHost.sortOrder), SortDescriptor(\SSHHost.name)]) private var hosts: [SSHHost]

    @State private var name = ""
    @State private var kind: PortForwardKind = .local
    @State private var hostID: UUID?
    @State private var bindAddress = "127.0.0.1"
    @State private var bindPort = ""
    @State private var targetHost = "localhost"
    @State private var targetPort = ""
    @State private var autoStart = false
    @State private var spec = ""

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private func port(_ text: String, allowZero: Bool) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (allowZero ? 0 : 1)...65535 ~= value else { return nil }
        return value
    }

    private var isValid: Bool {
        hostID != nil && port(bindPort, allowZero: true) != nil && (!kind.usesTarget || (port(targetPort, allowZero: false) != nil && !targetHost.trimmingCharacters(in: .whitespaces).isEmpty))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Host", selection: $hostID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(hosts) { host in
                            Text(host.name).tag(Optional(host.uuid))
                        }
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(PortForwardKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name, prompt: Text("Optional"))
                }
                Section(kind == .remote ? "Listen on the server" : "Listen on this Mac") {
                    TextField("Bind address", text: $bindAddress, prompt: Text("127.0.0.1"))
                    TextField("Port", text: $bindPort, prompt: Text(kind == .dynamic ? "1080" : "8080"))
                    Text(kind == .remote
                         ? "Use 0.0.0.0 to let other machines reach the server's port; sshd must have GatewayPorts enabled for that."
                         : "127.0.0.1 keeps the port private to this Mac; 0.0.0.0 opens it to your network. Port 0 picks any free port.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if kind.usesTarget {
                    Section(kind == .remote ? "Connect to (on this Mac)" : "Connect to (as seen from the server)") {
                        TextField("Host", text: $targetHost, prompt: Text("localhost"))
                        TextField("Port", text: $targetPort, prompt: Text("5432"))
                    }
                }
                Section {
                    TextField("ssh -\(kind == .local ? "L" : kind == .remote ? "R" : "D") spec", text: $spec, prompt: Text(kind == .dynamic ? "1080" : "8080:localhost:80"))
                        .font(.body.monospaced())
                        .onSubmit(applySpec)
                    Text("Paste an ssh-style spec and press Return to fill the fields above.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Start automatically when the host connects", isOn: $autoStart)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add Rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
        .onAppear(perform: load)
    }

    private func load() {
        switch target {
        case .create(let hostID):
            self.hostID = hostID ?? hosts.first?.uuid
        case .edit(let rule):
            name = rule.name
            kind = rule.kind
            hostID = rule.host?.uuid
            bindAddress = rule.bindAddress
            bindPort = String(rule.bindPort)
            targetHost = rule.targetHost
            targetPort = rule.targetPort == 0 ? "" : String(rule.targetPort)
            autoStart = rule.autoStart
        }
    }

    private func applySpec() {
        guard let parsed = PortForwardDescription.parse(spec, kind: kind) else { return }
        bindAddress = parsed.bindAddress
        bindPort = String(parsed.bindPort)
        if kind.usesTarget {
            targetHost = parsed.targetHost
            targetPort = String(parsed.targetPort)
        }
    }

    private func save() {
        guard let bind = port(bindPort, allowZero: true), let host = hosts.first(where: { $0.uuid == hostID }) else { return }
        let targetPortValue = kind.usesTarget ? (port(targetPort, allowZero: false) ?? 0) : 0
        let address = bindAddress.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : bindAddress.trimmingCharacters(in: .whitespaces)
        switch target {
        case .create:
            let rule = PortForwardRule(name: name.trimmingCharacters(in: .whitespaces), kind: kind, bindAddress: address, bindPort: bind, targetHost: kind.usesTarget ? targetHost.trimmingCharacters(in: .whitespaces) : "", targetPort: targetPortValue, autoStart: autoStart, sortOrder: host.portForwards.count, host: host)
            modelContext.insert(rule)
        case .edit(let rule):
            rule.name = name.trimmingCharacters(in: .whitespaces)
            rule.kind = kind
            rule.bindAddress = address
            rule.bindPort = bind
            rule.targetHost = kind.usesTarget ? targetHost.trimmingCharacters(in: .whitespaces) : ""
            rule.targetPort = targetPortValue
            rule.autoStart = autoStart
            rule.host = host
        }
        try? modelContext.save()
        dismiss()
    }
}
