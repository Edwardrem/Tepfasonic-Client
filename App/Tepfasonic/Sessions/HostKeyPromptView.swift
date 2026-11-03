import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

/// Trust-on-first-use sheet. For a changed key the safe choice (Cancel) is the default.
struct HostKeyPromptView: View {
    let host: HostDescriptor
    let key: HostKeyInfo
    let verdict: HostKeyVerdict
    let respond: (Bool) -> Void

    private var changed: KnownHostEntry? {
        if case .changed(let previous) = verdict { return previous }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(changed == nil ? "Unknown host key" : "Host key has changed",
                  systemImage: changed == nil ? "key.fill" : "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(changed == nil ? Color.primary : Color.orange)

            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Host").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("\(host.hostname):\(String(host.port))").textSelection(.enabled)
                    }
                    GridRow {
                        Text("Key type").foregroundStyle(.secondary)
                        Text(key.keyType)
                    }
                    GridRow {
                        Text("Fingerprint").foregroundStyle(.secondary)
                        Text(key.fingerprintSHA256).font(.body.monospaced()).textSelection(.enabled)
                    }
                    if let changed {
                        GridRow {
                            Text("Previously").foregroundStyle(.secondary)
                            Text(changed.fingerprintSHA256).font(.body.monospaced()).textSelection(.enabled)
                        }
                        GridRow {
                            Text("Saved on").foregroundStyle(.secondary)
                            Text(changed.addedAt, style: .date)
                        }
                    }
                }
                .padding(4)
            }

            HStack {
                if changed == nil {
                    Button("Cancel") { respond(false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Trust and Connect") { respond(true) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Replace Key and Connect", role: .destructive) { respond(true) }
                    Spacer()
                    Button("Cancel") { respond(false) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled()
    }

    private var explanation: String {
        if changed != nil {
            return "The key \(host.hostname) presented does not match the one saved earlier. This happens after a server reinstall, but it is also exactly what a man-in-the-middle attack looks like. Only continue if you can confirm the new fingerprint with whoever runs the server."
        }
        return "Tepfasonic has not connected to \(host.hostname) before. Compare the fingerprint with the one the server administrator gave you (ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub on the server) before trusting it."
    }
}
