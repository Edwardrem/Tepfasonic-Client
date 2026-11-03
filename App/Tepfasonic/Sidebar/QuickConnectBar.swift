import SwiftUI
import TepfaTerminal

/// `user@host:port` → connect without saving.
struct QuickConnectBar: View {
    @Environment(Workspace.self) private var workspace
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt")
                .foregroundStyle(.secondary)
            TextField("user@host:port", text: $text)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .onSubmit(connect)
                .onChange(of: text) { _, _ in invalid = false }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(invalid ? Color.red : Color(nsColor: .separatorColor)))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("Quick connect: user@host:port, Enter to connect without saving")
    }

    private func connect() {
        guard let descriptor = HostDescriptor.quickConnect(text) else {
            invalid = true
            return
        }
        workspace.openTab(host: descriptor)
        text = ""
    }
}
