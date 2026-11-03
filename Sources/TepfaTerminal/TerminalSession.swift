import AppKit
import Foundation
import Observation
import SwiftTerm
import TepfaCore
import TepfaSSH

/// Receives terminal output. Implemented by the SwiftTerm view coordinator.
@MainActor
public protocol TerminalSink: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
}

/// One terminal connected (or connecting) to one host. Owns the SSH
/// connection and shell, exposes observable state for the UI, asks the UI for
/// a password or host-key decision through `prompt`, and reconnects on its own
/// after a dropped connection.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int, delay: Int)
        case disconnected(String?)
        case failed(String)
    }

    /// A question the UI must answer before the connection can continue.
    /// Resume the continuation exactly once.
    public enum Prompt: Identifiable {
        case hostKey(HostKeyInfo, verdict: HostKeyVerdict, respond: CheckedContinuation<Bool, Never>)
        case password(respond: CheckedContinuation<SecretAnswer?, Never>)
        /// The identity's key needs a passphrase. `attemptFailed` is true after a wrong one.
        case passphrase(IdentityDescriptor, attemptFailed: Bool, respond: CheckedContinuation<SecretAnswer?, Never>)

        public var id: String {
            switch self {
            case .hostKey: "hostKey"
            case .password: "password"
            case .passphrase: "passphrase"
            }
        }
    }

    /// What the session is for.
    public enum Mode: String, Codable, Sendable {
        /// An interactive shell in a PTY.
        case shell
        /// No shell: the Claude agent runs commands over exec channels and the
        /// terminal shows each command and its output. Keystrokes are ignored.
        case agentLog
    }

    public static let maximumReconnectAttempts = 8

    public let id = UUID()
    public let host: HostDescriptor
    public let mode: Mode
    public private(set) var state: State = .idle
    public private(set) var title: String
    public var prompt: Prompt?
    /// The host (or jump host) the current prompt is about; `host` unless a bastion is asking.
    public private(set) var promptHost: HostDescriptor
    /// Bumped whenever the SSH connection is established or lost, so port
    /// forwarders and the SFTP browser can follow reconnects.
    public private(set) var connectionVersion = 0
    /// Serial consoles only: show incoming bytes as a hex dump.
    public var hexView = false
    /// Bytes received from the serial device so far (hex dump offsets).
    private var serialOffset = 0
    /// Host key presented by the server on the most recent attempt.
    public private(set) var hostKey: HostKeyInfo?
    public private(set) var cols = 80
    public private(set) var rows = 24
    public private(set) var currentDirectory: String?
    /// Where the remote shell is in its prompt cycle (OSC 133). `.unknown` until integration is seen.
    public private(set) var promptPhase: PromptPhase = .unknown
    /// True once the remote shell has emitted OSC 133 prompt markers.
    public private(set) var hasShellIntegration = false
    /// The command line rebuilt from keystrokes, for suggestions.
    public private(set) var typedLine = ""
    /// False after editing keys the tracker cannot follow (arrows, tab completion).
    public private(set) var typedLineIsReliable = true
    /// Receives each command with its exit status. Nil disables history.
    public var historyRecorder: (any CommandHistoryRecorder)?
    /// Set by the workspace; called when the terminal view gains focus.
    public var focusHandler: (() -> Void)?
    /// Called when the title changes.
    public var titleHandler: (() -> Void)?
    /// The terminal view currently showing this session.
    public weak var attachedView: NSView?

    private let knownHosts: KnownHostsStore
    private let credentialStore: any CredentialStore
    private var connection: SSHConnection? {
        didSet { connectionVersion += 1 }
    }
    private var shell: SSHShellSession?
    private var serialPort: SerialPort?
    private weak var sink: (any TerminalSink)?
    /// Output received before a terminal view attached.
    private var buffered: [UInt8] = []
    /// Incremented on every connect/disconnect so stale callbacks are ignored.
    private var generation = 0
    /// Remembered per hop (bastions and the host) for silent reconnects. Memory only; cleared when rejected.
    private var cachedCredentials: [UUID: SSHCredentials] = [:]
    /// Hops whose password came from the credential store, so a rejection deletes it.
    private var passwordFromStore: Set<UUID> = []
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    /// A headless terminal fed the same bytes as the view, so the buffer can be
    /// read for search and for the agent. SwiftTerm's view keeps its own private.
    private let mirror: Terminal
    private let mirrorDelegate = MirrorTerminalDelegate()
    private var oscObservation: TerminalOscObservation?
    private var typedTracker = TypedLineTracker()
    /// The last line submitted with Enter, for OSC 133 C when the buffer has no input cells.
    private var lastSubmittedTyped: String?
    private var currentCommandID: UUID?
    /// True while `sendCommand` is sending: the text is a command by definition.
    private var sendingCommand = false
    private var firstOutputSeen = false
    private var lastOutputAt = Date.distantPast
    /// True once the shell has had its first prompt and setup commands were sent.
    private var shellReady = false
    /// Commands to type once the shell is ready (e.g. "run on group" for a host still connecting).
    private var queuedCommands: [String] = []
    private var shellSetupTask: Task<Void, Never>?
    private var loginShellProbe: Task<String?, Never>?
    /// Set by `connect(shellIntegration:)` for tests; nil follows the host and global settings.
    private var shellIntegrationOverride: Bool?

    public init(
        host: HostDescriptor,
        mode: Mode = .shell,
        knownHosts: KnownHostsStore = .shared,
        credentialStore: any CredentialStore = KeychainCredentialStore.shared,
        historyRecorder: (any CommandHistoryRecorder)? = nil
    ) {
        self.host = host
        self.mode = mode
        self.knownHosts = knownHosts
        self.credentialStore = credentialStore
        self.historyRecorder = historyRecorder
        self.promptHost = host
        self.hexView = host.serial?.hexView ?? false
        self.title = mode == .agentLog ? "Agent · \(host.name)" : host.name
        var options = TerminalOptions.default
        options.scrollback = 2_000
        options.cols = 80
        options.rows = 24
        mirror = Terminal(delegate: mirrorDelegate, options: options)
        oscObservation = mirror.observeOscEvents { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleOsc(event)
                }
            }
        }
    }

    /// Whether the session will try to define OSC 133 hooks after connecting.
    public var wantsShellIntegration: Bool {
        if let shellIntegrationOverride { return shellIntegrationOverride }
        switch host.shellIntegration {
        case .enabled: return true
        case .disabled: return false
        case .automatic: return TerminalPreferences.shellIntegration
        }
    }

    /// Forces shell integration on or off for this session regardless of settings.
    public func overrideShellIntegration(_ enabled: Bool?) {
        shellIntegrationOverride = enabled
    }

    public var isConnected: Bool { state == .connected }

    /// The live SSH connection to the host (not a bastion), or nil while disconnected or serial.
    public var activeConnection: SSHConnection? {
        guard let connection, connection.isActive, state == .connected else { return nil }
        return connection
    }

    /// Waits until the session is connected (or has given up) and returns the connection.
    public func waitForConnection(timeout: Duration = .seconds(60)) async -> SSHConnection? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let connection = activeConnection { return connection }
            if case .failed = state { return nil }
            if case .disconnected = state { return nil }
            if case .idle = state { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return activeConnection
    }

    public var isBusy: Bool {
        switch state {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    // MARK: - Lifecycle

    public func connect() async {
        guard !isConnectingOrConnected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        await attemptConnection()
    }

    private var isConnectingOrConnected: Bool {
        switch state {
        case .connecting, .connected: true
        default: false
        }
    }

    private func attemptConnection() async {
        state = .connecting
        generation += 1
        let myGeneration = generation
        promptHost = host

        if host.isSerial {
            await attemptSerialConnection(generation: myGeneration)
            return
        }

        let connection: SSHConnection
        do {
            guard let established = try await establishChain(generation: myGeneration) else {
                if state == .connecting { state = .idle }
                return
            }
            connection = established
        } catch {
            guard myGeneration == generation else { return }
            self.connection = nil
            shell = nil
            let message = error.localizedDescription
            if reconnectAttempt > 0, case SSHClientError.connectionFailed = error {
                scheduleReconnect(after: "Reconnect failed: \(message)")
            } else {
                state = .failed(message)
                queuedCommands.removeAll()
            }
            return
        }
        guard myGeneration == generation else {
            connection.closeChain()
            return
        }
        self.connection = connection

        if mode == .agentLog {
            reconnectAttempt = 0
            state = .connected
            receive(Array("\u{1b}[2m[agent] connected to \(host.target); commands run over exec channels and appear here\u{1b}[0m\r\n".utf8), generation: myGeneration)
            return
        }

        do {
            let shell = try await connection.openShell(
                cols: cols,
                rows: rows,
                onOutput: { [weak self] bytes in
                    let copy = Array(bytes)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.receive(copy, generation: myGeneration)
                        }
                    }
                },
                onClose: { [weak self] reason in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.shellClosed(reason, generation: myGeneration)
                        }
                    }
                })
            guard myGeneration == generation else {
                shell.close()
                connection.closeChain()
                return
            }
            self.shell = shell
            reconnectAttempt = 0
            state = .connected
            beginShellSetup(connection: connection)
            // The view may have been resized while we were connecting.
            shell.resize(cols: cols, rows: rows)
        } catch {
            guard myGeneration == generation else { return }
            connection.closeChain()
            self.connection = nil
            shell = nil
            state = .failed(error.localizedDescription)
            queuedCommands.removeAll()
        }
    }

    /// Connects each bastion in turn, then the host through the last one.
    /// Returns nil when the user cancelled a prompt. Authentication failures
    /// clear the cached credentials of the hop that failed.
    private func establishChain(generation myGeneration: Int) async throws -> SSHConnection? {
        var via: SSHConnection?
        let hops = host.jumpChain + [host.withoutJumpChain()]
        let firstProxy = host.jumpChain.first?.proxy ?? host.proxy
        for (index, hop) in hops.enumerated() {
            let isTarget = index == hops.count - 1
            promptHost = hop
            guard let credentials = await gatherCredentials(for: hop) else {
                via?.closeChain()
                return nil
            }
            guard myGeneration == generation else {
                via?.closeChain()
                return nil
            }
            var proxy: ProxySettings?
            if index == 0, let configured = firstProxy {
                proxy = try await resolveProxy(configured)
            }
            let verifier = ClosureHostKeyVerifier { [weak self] key, _, _ in
                guard let self else { return false }
                return await self.verifyHostKey(key, for: hop, isTarget: isTarget)
            }
            do {
                let connection = try await SSHConnection.connect(
                    host: hop.hostname,
                    port: hop.port,
                    credentials: credentials,
                    hostKeyVerifier: verifier,
                    proxy: proxy,
                    via: via)
                via = connection
            } catch {
                via?.closeChain()
                if case SSHClientError.authenticationFailed = error {
                    cachedCredentials[hop.id] = nil
                    if passwordFromStore.contains(hop.id) {
                        credentialStore.forgetPassword(for: hop)
                        passwordFromStore.remove(hop.id)
                        let message = error.localizedDescription + " The saved password was rejected and has been removed; you will be asked next time."
                        throw isTarget ? SSHClientError.authenticationFailed(message) : SSHClientError.connectionFailed("Jump host \(hop.name): \(message)")
                    }
                }
                if isTarget { throw error }
                throw SSHClientError.connectionFailed("Jump host \(hop.name): \(error.localizedDescription)")
            }
        }
        promptHost = host
        return via
    }

    /// The proxy with its password, when one is saved for the host or group that owns it.
    private func resolveProxy(_ configured: HostProxyConfiguration) async throws -> ProxySettings {
        var settings = ProxySettings(kind: ProxySettings.Kind(rawValue: configured.kind) ?? .http, host: configured.host, port: configured.port, username: configured.username)
        if configured.username != nil {
            do {
                settings.password = try await credentialStore.proxyPassword(ownerID: configured.ownerID)
            } catch VaultError.cancelled {
                throw CredentialResolver.Failure.cancelled
            } catch {
                notice("Could not read the proxy password: \(error.localizedDescription)")
            }
        }
        return settings
    }

    // MARK: - Serial

    private func attemptSerialConnection(generation myGeneration: Int) async {
        guard let settings = host.serial else { return }
        serialOffset = 0
        let port = SerialPort(
            settings: settings,
            onData: { [weak self] bytes in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receiveSerial(bytes, generation: myGeneration) }
                }
            },
            onClose: { [weak self] reason in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.serialClosed(reason, generation: myGeneration) }
                }
            })
        do {
            try port.open()
        } catch {
            guard myGeneration == generation else { return }
            if reconnectAttempt > 0 {
                scheduleReconnect(after: "Reconnect failed: \(error.localizedDescription)")
            } else {
                state = .failed(error.localizedDescription)
            }
            return
        }
        guard myGeneration == generation else {
            port.close()
            return
        }
        serialPort = port
        reconnectAttempt = 0
        state = .connected
        shellReady = true
        notice("Opened \(settings.devicePath) at \(settings.lineSummary)\(hexView ? ", hex view" : "")")
        let queued = queuedCommands
        queuedCommands.removeAll()
        for command in queued { sendCommand(command) }
    }

    private func receiveSerial(_ bytes: [UInt8], generation: Int) {
        guard generation == self.generation, let settings = host.serial else { return }
        if hexView {
            receive(Array(HexDump.lines(bytes, offset: serialOffset).utf8), generation: generation)
        } else if settings.convertIncomingLF {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + 8)
            var previous: UInt8 = 0
            for byte in bytes {
                if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
                out.append(byte)
                previous = byte
            }
            receive(out, generation: generation)
        } else {
            receive(bytes, generation: generation)
        }
        serialOffset += bytes.count
    }

    private func serialClosed(_ reason: String?, generation: Int) {
        guard generation == self.generation else { return }
        self.generation += 1
        serialPort = nil
        notice(reason ?? "Serial port closed")
        if let reason, host.autoReconnect {
            scheduleReconnect(after: reason)
        } else {
            state = .disconnected(reason ?? "Disconnected")
        }
    }

    /// Keystrokes for a serial console: Return becomes the configured line ending.
    private func sendSerial(_ bytes: ArraySlice<UInt8>, settings: SerialSettings) {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for byte in bytes {
            if byte == 0x0D {
                out.append(contentsOf: settings.sendLineEnding.bytes)
            } else {
                out.append(byte)
            }
        }
        serialPort?.write(out)
        if settings.localEcho, !hexView {
            var echo: [UInt8] = []
            for byte in bytes {
                if byte == 0x0D { echo.append(contentsOf: [0x0D, 0x0A]) } else { echo.append(byte) }
            }
            mirror.feed(byteArray: echo)
            sink?.feed(echo[...])
        }
    }

    public func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        cancelShellSetup()
        shellReady = false
        queuedCommands.removeAll()
        shell?.close()
        connection?.closeChain()
        serialPort?.close()
        serialPort = nil
        shell = nil
        connection = nil
        if case .connected = state {
            notice("Disconnected")
        }
        state = .disconnected("Disconnected")
    }

    public func reconnect() async {
        disconnect()
        await connect()
    }

    /// Drops the saved host key for this host and connects again. Used after a
    /// "host key changed" refusal the user has decided is legitimate.
    public func forgetHostKeyAndReconnect() async {
        let hop = promptHost
        try? await knownHosts.forget(host: hop.hostname, port: hop.port)
        await reconnect()
    }

    /// After sleep the TCP connection is usually dead but not yet closed; poke
    /// it so the failure surfaces and the reconnect logic runs.
    public func systemDidWake() {
        guard state == .connected, let shell else { return }
        shell.resize(cols: cols, rows: rows)
    }

    // MARK: - Terminal I/O

    /// Keyboard input from the terminal view.
    public func send(_ bytes: ArraySlice<UInt8>) {
        guard mode == .shell else { return }
        if let settings = host.serial {
            sendSerial(bytes, settings: settings)
        } else {
            shell?.write(bytes)
        }
        guard !mirror.isCurrentBufferAlternate else { return }
        switch typedTracker.consume(bytes) {
        case .submitted(let line):
            lastSubmittedTyped = line
            if !hasShellIntegration, sendingCommand || mirrorEchoed(line) { recordTypedCommand(line) }
        case .cancelled:
            lastSubmittedTyped = nil
        case .none:
            break
        }
        publishTypedLine()
    }

    public func send(text: String) {
        send(ArraySlice(text.utf8))
    }

    /// Types `command` into the shell and presses Enter. Multi-line commands
    /// are sent line by line.
    public func sendCommand(_ command: String) {
        let text = command.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        sendingCommand = true
        defer { sendingCommand = false }
        send(text: text.hasSuffix("\r") ? text : text + "\r")
    }

    /// Types `command` now if the shell is ready, otherwise once the connection
    /// is up and its first prompt has appeared. Dropped if the connection fails.
    public func sendCommandWhenReady(_ command: String) {
        if shellReady, isConnected {
            sendCommand(command)
        } else {
            queuedCommands.append(command)
        }
    }

    /// Replaces what the user has typed so far on the current line with `text`
    /// (used when a suggestion is accepted). Only safe while the typed line is reliable.
    public func replaceTypedLine(with text: String) {
        guard typedLineIsReliable else { return }
        var bytes: [UInt8] = []
        if text.hasPrefix(typedLine) {
            bytes.append(contentsOf: text.dropFirst(typedLine.count).utf8)
        } else {
            bytes.append(0x15) // ^U
            bytes.append(contentsOf: text.utf8)
        }
        send(bytes[...])
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        mirror.resize(cols: cols, rows: rows)
        shell?.resize(cols: cols, rows: rows)
    }

    public func updateTitle(_ title: String) {
        let newTitle = title.isEmpty ? host.name : title
        guard newTitle != self.title else { return }
        self.title = newTitle
        titleHandler?()
    }

    /// Takes the OSC 7 report (`file://host/path`) or a plain path.
    public func updateCurrentDirectory(_ directory: String?) {
        guard let directory else {
            currentDirectory = nil
            return
        }
        currentDirectory = WorkingDirectoryReport.path(from: Array(directory.utf8)) ?? directory
    }

    public func attach(_ sink: any TerminalSink) {
        self.sink = sink
        if !buffered.isEmpty {
            sink.feed(buffered[...])
            buffered.removeAll()
        }
    }

    public func detach() {
        sink = nil
    }

    public func noteFocused() {
        focusHandler?()
    }

    public func requestFocus() {
        guard let view = attachedView, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    /// Runs one command over an exec channel on this session's connection and
    /// shows it in the terminal (`echoOutput: false` shows the command and its
    /// exit status but keeps the output, e.g. file contents, out of the log).
    /// Reconnects first when the connection dropped. Cancelling the task
    /// closes the channel and stops the remote command.
    public func runCommand(
        _ command: String,
        stdin: [UInt8] = [],
        outputLimit: Int = 1 << 20,
        timeout: Duration = .seconds(120),
        echo: Bool = true,
        echoOutput: Bool = true
    ) async throws -> CommandResult {
        if host.isSerial {
            throw SSHClientError.channelFailed("serial consoles cannot run commands over exec channels")
        }
        if connection == nil || connection?.isActive == false {
            if case .connecting = state {} else { await connect() }
            while case .connecting = state { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard let connection, connection.isActive, state == .connected else {
            throw SSHClientError.connectionFailed(stateDescription)
        }
        let myGeneration = generation
        if echo {
            receive(Array("\r\n\u{1b}[1;36m$ \(command)\u{1b}[0m\r\n".utf8), generation: myGeneration)
        }
        let seconds = Int64(timeout.components.seconds)
        do {
            let result = try await connection.run(command, stdin: stdin, outputLimit: outputLimit, timeout: .seconds(seconds))
            if echo {
                if echoOutput {
                    if !result.stdout.isEmpty { receive(Self.terminalBytes(result.stdout), generation: myGeneration) }
                    if !result.stderr.isEmpty { receive(Self.terminalBytes(result.stderr), generation: myGeneration) }
                } else {
                    let size = result.stdout.count + result.stderr.count
                    receive(Array("\u{1b}[2m(\(size) bytes not shown)\u{1b}[0m\r\n".utf8), generation: myGeneration)
                }
                let status = result.exitStatus.map { "exit \($0)" } ?? result.signal.map { "signal \($0)" } ?? "no exit status"
                let color = result.succeeded ? "32" : "33"
                receive(Array("\u{1b}[\(color)m[\(status)]\u{1b}[0m\r\n".utf8), generation: myGeneration)
            }
            return result
        } catch {
            if echo {
                let message = error is CancellationError || (error as? SSHClientError) == .cancelled ? "stopped" : error.localizedDescription
                receive(Array("\u{1b}[31m[\(message)]\u{1b}[0m\r\n".utf8), generation: myGeneration)
            }
            throw error
        }
    }

    private var stateDescription: String {
        switch state {
        case .failed(let message): message
        case .disconnected(let reason): reason ?? "disconnected"
        case .idle: "not connected"
        default: "not connected"
        }
    }

    /// Converts bare newlines to CR LF so exec output renders in a terminal.
    private static func terminalBytes(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 0x0A && previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            previous = byte
        }
        if let last = out.last, last != 0x0A { out.append(contentsOf: [0x0D, 0x0A]) }
        return out
    }

    /// Text of the terminal buffer (scrollback plus screen), most recent rows last.
    public func bufferText(maximumRows: Int = 500) -> String {
        let snapshot = mirror.contentSnapshot(region: .history(maximumScrollbackRows: maximumRows), buffer: .active)
        var lines = snapshot.rows.map(\.text)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private func gatherCredentials(for hop: HostDescriptor) async -> SSHCredentials? {
        if let cached = cachedCredentials[hop.id] { return cached }
        let resolver = CredentialResolver(
            store: credentialStore,
            askPassword: { [weak self] _ in
                guard let self else { return nil }
                let answer: SecretAnswer? = await withCheckedContinuation { continuation in
                    self.prompt = .password(respond: continuation)
                }
                self.prompt = nil
                return answer
            },
            askPassphrase: { [weak self] identity, attemptFailed in
                guard let self else { return nil }
                let answer: SecretAnswer? = await withCheckedContinuation { continuation in
                    self.prompt = .passphrase(identity, attemptFailed: attemptFailed, respond: continuation)
                }
                self.prompt = nil
                return answer
            },
            notify: { [weak self] message in self?.notice(message) })
        do {
            let resolution = try await resolver.resolve(for: hop)
            if resolution.passwordFromStore { passwordFromStore.insert(hop.id) } else { passwordFromStore.remove(hop.id) }
            cachedCredentials[hop.id] = resolution.credentials
            return resolution.credentials
        } catch CredentialResolver.Failure.cancelled {
            return nil
        } catch {
            state = .failed(hop.id == host.id ? error.localizedDescription : "Jump host \(hop.name): \(error.localizedDescription)")
            return nil
        }
    }

    private func verifyHostKey(_ key: HostKeyInfo, for hop: HostDescriptor, isTarget: Bool) async -> Bool {
        if isTarget { hostKey = key }
        let verdict = await knownHosts.verdict(
            host: hop.hostname, port: hop.port, keyType: key.keyType, publicKey: key.openSSHPublicKey)
        if verdict == .known {
            return true
        }
        promptHost = hop
        let accepted: Bool = await withCheckedContinuation { continuation in
            prompt = .hostKey(key, verdict: verdict, respond: continuation)
        }
        prompt = nil
        if accepted {
            try? await knownHosts.remember(
                host: hop.hostname, port: hop.port, keyType: key.keyType,
                publicKey: key.openSSHPublicKey, fingerprintSHA256: key.fingerprintSHA256)
        }
        return accepted
    }

    private func receive(_ bytes: [UInt8], generation: Int) {
        guard generation == self.generation else { return }
        mirror.feed(byteArray: bytes)
        if let sink {
            sink.feed(bytes[...])
        } else {
            buffered.append(contentsOf: bytes)
        }
        lastOutputAt = .now
        firstOutputSeen = true
    }

    // MARK: - Shell integration and command history

    private func beginShellSetup(connection: SSHConnection) {
        cancelShellSetup()
        firstOutputSeen = false
        shellReady = false
        promptPhase = .unknown
        hasShellIntegration = false
        currentCommandID = nil
        lastSubmittedTyped = nil
        typedTracker.reset()
        publishTypedLine()
        if wantsShellIntegration {
            // Ask for the login shell now so the answer is ready when the prompt appears.
            loginShellProbe = Task.detached {
                let result = try? await connection.run(" echo $SHELL", timeout: .seconds(8))
                return result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        scheduleShellSetup(generation: generation)
    }

    /// True when output has paused and the cursor sits after some text: the
    /// shell has most likely printed its prompt and is waiting for input.
    private var looksLikeAPrompt: Bool {
        firstOutputSeen && Date.now.timeIntervalSince(lastOutputAt) >= 0.3 && mirror.getCursorLocation().x > 0
    }

    private func cancelShellSetup() {
        shellSetupTask?.cancel()
        shellSetupTask = nil
        loginShellProbe?.cancel()
        loginShellProbe = nil
    }

    /// Waits for the first prompt (output pauses with the cursor after text, or
    /// OSC 133 arrives), installs the hooks when the shell is bash/zsh and has
    /// none, then sends the host's startup command and anything queued.
    private func scheduleShellSetup(generation: Int) {
        shellSetupTask = Task { [weak self] in
            let started = ContinuousClock.now
            var promptSeen = false
            while !promptSeen {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                promptSeen = self.hasShellIntegration || self.looksLikeAPrompt
                if ContinuousClock.now - started > .seconds(10) { break }
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            if promptSeen, self.wantsShellIntegration, !self.hasShellIntegration {
                let loginShell = await self.loginShellProbe?.value
                guard !Task.isCancelled, generation == self.generation, !self.hasShellIntegration else { return }
                if let loginShell, ShellIntegration.supports(loginShell: loginShell) {
                    self.installShellIntegration()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            if let command = self.host.startupCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.sendCommand(command)
            }
            self.shellReady = true
            let queued = self.queuedCommands
            self.queuedCommands.removeAll()
            for command in queued { self.sendCommand(command) }
        }
    }

    private func installShellIntegration() {
        guard let shell, typedTracker.text.isEmpty, !mirror.isCurrentBufferAlternate else { return }
        let cursor = mirror.getCursorLocation()
        let line = ShellIntegration.installLine(cursorColumn: cursor.x, columns: mirror.cols)
        shell.write(ArraySlice((line + "\r").utf8))
    }

    private func handleOsc(_ event: TerminalOscEvent) {
        guard event.code == 133, let action = SemanticPromptAction(payload: event.payload) else { return }
        hasShellIntegration = true
        switch action {
        case .promptStart:
            promptPhase = .prompt
        case .inputStart:
            promptPhase = .prompt
            typedTracker.reset()
            publishTypedLine()
        case .commandStart:
            promptPhase = .running
            let command = latestInputText() ?? lastSubmittedTyped ?? ""
            lastSubmittedTyped = nil
            guard !command.isEmpty, let historyRecorder else { return }
            let record = CommandRecord(
                command: command,
                hostID: host.isTransient ? nil : host.id,
                hostName: host.name,
                hostTarget: host.target,
                workingDirectory: currentDirectory,
                source: .shellIntegration)
            currentCommandID = record.id
            historyRecorder.commandStarted(record)
        case .commandEnd(let status):
            promptPhase = .prompt
            if let id = currentCommandID {
                historyRecorder?.commandFinished(id: id, exitStatus: status, at: .now)
                currentCommandID = nil
            }
        }
    }

    /// Text of the most recent run of OSC 133 input cells in the mirror buffer:
    /// the command the shell is about to run, as the shell displayed it.
    private func latestInputText() -> String? {
        let top = mirror.getTopVisibleRow()
        let bottom = top + mirror.rows - 1
        var rows: [Int] = []
        var row = bottom
        scan: while row >= 0, bottom - row < 60 {
            var hasInput = false
            var startsPrompt = false
            for col in 0..<mirror.cols {
                switch mirror.semanticContent(at: Position(col: col, row: row)) {
                case .input: hasInput = true
                case .prompt(.initial): startsPrompt = true
                default: break
                }
            }
            if hasInput {
                rows.append(row)
            } else if !rows.isEmpty {
                break scan
            }
            if startsPrompt, !rows.isEmpty { break scan } // the row the group began on
            row -= 1
        }
        guard !rows.isEmpty else { return nil }
        var text = ""
        for row in rows.reversed() {
            guard let line = mirror.getScrollInvariantLine(row: row + mirror.buffer.totalLinesTrimmed) else { continue }
            var rowText = ""
            for col in 0..<mirror.cols where mirror.semanticContent(at: Position(col: col, row: row)) == .input {
                rowText += mirror.getText(for: line[col])
            }
            if !text.isEmpty, !line.isWrapped { text += "\n" }
            text += rowText
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Without shell integration, Enter on a reliable typed line records a command.
    private func recordTypedCommand(_ line: String) {
        guard let historyRecorder else { return }
        historyRecorder.commandStarted(CommandRecord(
            command: line,
            hostID: host.isTransient ? nil : host.id,
            hostName: host.name,
            hostTarget: host.target,
            workingDirectory: currentDirectory,
            source: .typed))
    }

    /// True when the typed text is on screen near the cursor at the moment
    /// Enter is pressed, as the tty echoes keystrokes one by one. Text typed
    /// at a password prompt is not echoed and so is never recorded.
    private func mirrorEchoed(_ line: String) -> Bool {
        let cursor = mirror.getCursorLocation()
        var text = ""
        for row in max(0, cursor.y - 4)...cursor.y {
            if let bufferLine = mirror.getLine(row: row) {
                text += bufferLine.translateToString(trimRight: true)
            }
        }
        return text.contains(String(line.prefix(24)))
    }

    private func publishTypedLine() {
        if typedLine != typedTracker.text { typedLine = typedTracker.text }
        if typedLineIsReliable != typedTracker.isReliable { typedLineIsReliable = typedTracker.isReliable }
    }

    private func shellClosed(_ reason: ShellCloseReason, generation: Int) {
        guard generation == self.generation else { return }
        self.generation += 1
        shell = nil
        connection?.closeChain()
        connection = nil
        let cleanExit = reason.exitStatus != nil || reason.signal != nil
        notice(reason.message)
        if !cleanExit, host.autoReconnect {
            scheduleReconnect(after: reason.message)
        } else {
            state = .disconnected(reason.message)
        }
    }

    private func scheduleReconnect(after message: String) {
        reconnectAttempt += 1
        guard reconnectAttempt <= Self.maximumReconnectAttempts else {
            reconnectAttempt = 0
            state = .failed("\(message). Gave up after \(Self.maximumReconnectAttempts) reconnect attempts.")
            return
        }
        let delay = min(30, 1 << (reconnectAttempt - 1))
        state = .reconnecting(attempt: reconnectAttempt, delay: delay)
        notice("Reconnecting in \(delay)s (attempt \(reconnectAttempt) of \(Self.maximumReconnectAttempts))…")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.attemptConnection()
        }
    }

    /// Prints a dim status line into the terminal.
    private func notice(_ message: String) {
        let text = "\r\n\u{1B}[2m[\(message)]\u{1B}[0m\r\n"
        let bytes = Array(text.utf8)
        mirror.feed(byteArray: bytes)
        if let sink {
            sink.feed(bytes[...])
        } else {
            buffered.append(contentsOf: bytes)
        }
    }
}

/// Delegate for the headless mirror terminal: nothing is sent back to anyone.
final class MirrorTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
