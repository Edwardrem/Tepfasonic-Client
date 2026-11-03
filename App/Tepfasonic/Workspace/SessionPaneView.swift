import AppKit
import Combine
import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

/// One terminal pane: the SwiftTerm view, state overlays, prompts, the host
/// colour stripe, and the theming extras (tint, watermark, badge, blur).
struct SessionPaneView: View {
    let tabID: UUID
    let leafID: UUID
    let sessionID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themes
    @AppStorage("ui.showColorStripes") private var showColorStripes = true

    var body: some View {
        if let session = workspace.session(id: sessionID) {
            SessionPaneContent(
                session: session,
                appearance: themes.resolve(session.host.appearance),
                isFocused: workspace.isFocused(leafID: leafID),
                showsFocusRing: !(workspace.selectedTab?.tree.isLeaf ?? true),
                showColorStripe: showColorStripes
            ) {
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
    let appearance: TerminalAppearance
    let isFocused: Bool
    let showsFocusRing: Bool
    let showColorStripe: Bool
    let close: () -> Void
    let save: () -> Void
    @AppStorage(TerminalPreferences.backgroundBlurKey) private var backgroundBlur = true
    @AppStorage(TerminalPreferences.badgeEnabledKey) private var badgeEnabled = false

    var body: some View {
        ZStack {
            if appearance.backgroundOpacity < 1, backgroundBlur {
                VisualEffectBackground()
            }
            TerminalSessionView(session: session, appearance: appearance)
            if let tint = HostColor.color(session.host.appearance.backgroundTint) {
                tint.opacity(0.12).allowsHitTesting(false)
            }
            if let watermark = session.host.appearance.watermark, !watermark.isEmpty {
                WatermarkView(text: watermark, color: HostColor.color(session.host.appearance.backgroundTint) ?? HostColor.color(session.host.colorLabel) ?? Color(nsColor: TerminalAppearance.nsColor(appearance.theme.foreground)))
            }
            if badgeEnabled, !session.host.isTransient || session.isConnected {
                SessionBadge(session: session)
            }
            if isFocused {
                SuggestionsOverlay(session: session)
            }
            overlays
        }
        .background(WindowTransparency(transparent: appearance.backgroundOpacity < 1))
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
        .onReceive(NotificationCenter.default.publisher(for: .tepfaFindInTerminal)) { _ in
            guard isFocused else { return }
            (session.attachedView as? TepfaTerminalView)?.showFind()
        }
        .sheet(item: $session.prompt) { prompt in
            switch prompt {
            case .hostKey(let key, let verdict, let respond):
                HostKeyPromptView(host: session.promptHost, key: key, verdict: verdict) { trusted in
                    respond.resume(returning: trusted)
                }
            case .password(let respond):
                PasswordPromptView(host: session.promptHost) { answer in
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
                if !session.host.routeDescription.isEmpty {
                    Text(session.host.routeDescription).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(session.host.isSerial ? "Open" : "Connect") { Task { await session.connect() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Button("Close", action: close)
                }
            }
        case .connecting:
            OverlayCard {
                ProgressView(session.host.isSerial ? "Opening \(session.host.hostname)…" : "Connecting to \(session.host.target)…")
                if session.promptHost.id != session.host.id {
                    Text("Through \(session.promptHost.name)").font(.caption).foregroundStyle(.secondary)
                }
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

/// Large faint text across the terminal, such as PROD.
private struct WatermarkView: View {
    let text: String
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(.system(size: min(geometry.size.width / CGFloat(max(text.count, 1)) * 1.4, geometry.size.height * 0.5), weight: .black, design: .rounded))
                .foregroundStyle(color.opacity(0.08))
                .rotationEffect(.degrees(-18))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .minimumScaleFactor(0.2)
                .lineLimit(1)
        }
        .allowsHitTesting(false)
    }
}

/// The corner badge: host name, user and how long the session has been up.
private struct SessionBadge: View {
    let session: TerminalSession
    @AppStorage(TerminalPreferences.badgePositionKey) private var position = "topRight"
    @AppStorage(TerminalPreferences.badgeColorKey) private var colorHex = ""
    @AppStorage(TerminalPreferences.badgeShowsUserKey) private var showsUser = true
    @AppStorage(TerminalPreferences.badgeShowsUptimeKey) private var showsUptime = true
    @State private var now = Date.now
    @State private var connectedSince: Date?
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var alignment: Alignment {
        switch position {
        case "topLeft": .topLeading
        case "bottomLeft": .bottomLeading
        case "bottomRight": .bottomTrailing
        default: .topTrailing
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(session.host.name)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            if showsUser, !session.host.isSerial {
                Text(session.host.loginUsername + "@" + session.host.hostname)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            if showsUptime, let since = connectedSince, session.isConnected {
                Text("up " + uptime(since: since))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle((HostColor.color(colorHex.isEmpty ? nil : colorHex) ?? HostColor.color(session.host.colorLabel) ?? .white).opacity(0.35))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .allowsHitTesting(false)
        .onReceive(timer) { now = $0 }
        .onChange(of: session.isConnected, initial: true) { _, connected in
            connectedSince = connected ? (connectedSince ?? .now) : nil
        }
    }

    private func uptime(since: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since))
        if seconds < 60 { return "<1m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// A blurred view of what is behind the window, for translucent backgrounds.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Makes the hosting window see-through while any pane uses a translucent background.
private struct WindowTransparency: NSViewRepresentable {
    let transparent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else if !window.isOpaque {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }
}

struct SessionStatusBar: View {
    let session: TerminalSession
    @Environment(AppState.self) private var appState
    @Environment(PortForwardingManager.self) private var forwarding
    @Environment(\.openWindow) private var openWindow

    private var activeForwardCount: Int {
        forwarding.activeForwards.filter { $0.rule.hostID == session.host.id && $0.status.isActive }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !session.host.routeDescription.isEmpty {
                Text(session.host.routeDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Connection route")
            }
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
            if activeForwardCount > 0 {
                Button {
                    appState.sidebarMode = .ports
                } label: {
                    Label("\(activeForwardCount)", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("\(activeForwardCount) port forwarding rule(s) active")
            }
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
            if session.host.isSerial {
                Toggle("Hex", isOn: Binding(get: { session.hexView }, set: { session.hexView = $0 }))
                    .toggleStyle(.button)
                    .help("Show incoming bytes as a hex dump")
            } else if session.isConnected, !session.host.isTransient {
                Button {
                    appState.sftpHostID = session.host.id
                    openWindow(id: "sftp")
                } label: {
                    Label("Files", systemImage: "folder")
                }
                .help("Browse files on this host over SFTP (⌥⌘O)")
            }
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
        case .connected: session.host.isSerial ? "Open: \(session.host.target)" : "Connected to \(session.host.target)"
        case .disconnected(let reason): reason ?? "Disconnected"
        case .failed: "Connection failed"
        }
    }
}
