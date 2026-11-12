import SwiftUI
import TepfaTerminal

/// `user@host:port` → connect without saving.
struct QuickConnectBar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(invalid ? Color.red : Design.Tint.quick)
            TextField("user@host:port", text: $text)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .focused($focused)
                .onSubmit(connect)
                .onChange(of: text) { _, _ in invalid = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(invalid ? Color.red : (focused ? (palette.accent ?? .accentColor).opacity(0.7) : palette.separator), lineWidth: invalid || focused ? 1 : 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
