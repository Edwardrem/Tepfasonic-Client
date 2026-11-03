import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

/// One terminal pane: the SwiftTerm view, state overlays, prompts and the host colour stripe.
struct SessionPaneView: View {
    let tabID: UUID
    let leafID: UUID
    let sessionID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppState.self) private var appState
    @AppStorage("ui.showColorStripes") private var showColorStripes = true

    var body: some View {
        if let session = workspace.session(id: sessionID) {
            SessionPaneContent(session: session, isFocused: workspace.isFocused(leafID: leafID), showsFocusRing: !(workspace.selectedTab?.tree.isLeaf ?? true), showColorStripe: showColorStripes) {
                workspace.closePane(leafID: leafID, inTab: tabID)
            } save: {
                appState.hostEditor = .createFrom(session.host)
            }
            .onTapGesture { workspace.focus(leafID: leafID) }
        } else {
            ContentUnavailableView("Session Closed", systemImage: "terminal")
        }
    }
}

private struct SessionPaneContent: View {
    @Bindable var session: TerminalSession
    let isFocused: Bool
    let showsFocusRing: Bool
    let showColorStripe: Bool
    let close: () -> Void
    let save: () -> Void

    var body: some View {
        ZStack {
            TerminalSessionView(session: session)
            if isFocused {
                SuggestionsOverlay(session: session)
            }
            overlays
        }
        .overlay(alignment: .top) {
            if showColorStripe, let color = HostColor.color(session.host.colorLabel) {
                Rectangle().fill(color).frame(height: 3)
            }
        }
        .overlay {
            if showsFocusRing {
                Rectangle()
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $session.prompt) { prompt in
            switch prompt {
            case .hostKey(let key, let verdict, let respond):
                HostKeyPromptView(host: session.host, key: key, verdict: verdict) { trusted in
                    respond.resume(returning: trusted)
                }
            case .password(let respond):
                PasswordPromptView(host: session.host) { answer in
                    respond.resume(returning: answer)
                }
            case .passphrase(let identity, let attemptFailed, let respond):
                PassphrasePromptView(identity: identity, attemptFailed: attemptFailed) { answer in
                    respond.resume(returning: answer)
                }
            }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        switch session.state {
        case .idle:
            OverlayCard {
                Text(session.host.name).font(.headline)
                Text(session.host.target).font(.callout.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Button("Connect") { Task { await session.connect() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Button("Close", action: close)
                }
            }
        case .connecting:
            OverlayCard {
                ProgressView("Connecting to \(session.host.target)…")
            }
        case .reconnecting(let attempt, let delay):
            OverlayCard {
                ProgressView("Connection lost. Reconnecting in \(delay)s (attempt \(attempt))…")
                Button("Stop") { session.disconnect() }
            }
        case .failed(let message):
            OverlayCard {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 420)
                HStack {
                    Button("Try Again") { Task { await session.reconnect() } }.keyboardShortcut(.defaultAction)
                    Button("Close", action: close)
                }
            }
        case .disconnected(let reason):
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Text(reason ?? "Disconnected").foregroundStyle(.secondary)
                    Button("Reconnect") { Task { await session.reconnect() } }.keyboardShortcut(.defaultAction)
                    Button("Close", action: close)
                }
                .controlSize(.small)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 12)
            }
        case .connected:
            if session.host.isTransient {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            save()
                        } label: {
                            Label("Save Host…", systemImage: "square.and.arrow.down")
                        }
                        .controlSize(.small)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct OverlayCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SessionStatusBar: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let key = session.hostKey {
                Text("\(key.keyType) \(key.fingerprintSHA256)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Server host key fingerprint")
            }
            Spacer()
            if session.hasShellIntegration {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(session.promptPhase == .running ? .orange : .green)
                    .help(session.promptPhase == .running ? "Shell integration active: a command is running" : "Shell integration active: commands are recorded with their exit status")
            }
            if let directory = session.currentDirectory {
                Text(directory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(session.cols)×\(session.rows)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            if session.isConnected {
                Button("Disconnect") { session.disconnect() }
            } else if !session.isBusy {
                Button("Reconnect") { Task { await session.reconnect() } }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .idle, .disconnected: .secondary
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .reconnecting(let attempt, _): "Reconnecting (attempt \(attempt))…"
        case .connected: "Connected to \(session.host.target)"
        case .disconnected(let reason): reason ?? "Disconnected"
        case .failed: "Connection failed"
        }
    }
}
