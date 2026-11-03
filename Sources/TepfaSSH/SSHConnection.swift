import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// An authenticated SSH connection. Create one with `connect`, then open
/// shells, exec channels, subsystems or forwarded TCP channels on it.
/// Closing the connection closes every channel.
///
/// A connection can go through an HTTP or SOCKS5 proxy, or through another
/// `SSHConnection` acting as a jump host: the target's SSH stream is then
/// multiplexed over a direct-tcpip channel of the bastion, never a shell.
public final class SSHConnection: @unchecked Sendable {
    public let host: String
    public let port: Int
    /// The host key the server presented.
    public let hostKey: HostKeyInfo?
    /// The bastion this connection is tunnelled through, if any. Closing this
    /// connection does not close the bastion; the owner decides.
    public let via: SSHConnection?
    /// Receives `forwarded-tcpip` channels for remote port forwarding.
    public let forwardedChannels: ForwardedChannelRouter

    let channel: Channel

    private init(host: String, port: Int, hostKey: HostKeyInfo?, channel: Channel, via: SSHConnection?, forwardedChannels: ForwardedChannelRouter) {
        self.host = host
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
        self.via = via
        self.forwardedChannels = forwardedChannels
    }

    public var isActive: Bool { channel.isActive }

    /// The event loop the connection runs on; forwarders bind there so their
    /// channels share it.
    public var eventLoop: any EventLoop { channel.eventLoop }

    /// Connects, verifies the host key through `hostKeyVerifier`, and authenticates.
    ///
    /// - Parameters:
    ///   - proxy: an HTTP CONNECT or SOCKS5 proxy for the TCP connection. Ignored when `via` is given.
    ///   - via: a connected bastion; the target is reached through a direct-tcpip channel on it.
    public static func connect(
        host: String,
        port: Int = 22,
        credentials: SSHCredentials,
        hostKeyVerifier: any HostKeyVerifier,
        connectTimeout: TimeAmount = .seconds(15),
        proxy: ProxySettings? = nil,
        via: SSHConnection? = nil,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> SSHConnection {
        let loop: any EventLoop = via?.channel.eventLoop ?? group.next()
        let authenticated = loop.makePromise(of: Void.self)
        let authDelegate = ClientAuthDelegate(credentials: credentials)
        let hostKeyDelegate = HostKeyDelegate(host: host, port: port, verifier: hostKeyVerifier)
        let router = ForwardedChannelRouter()

        let addSSHHandlers: @Sendable (Channel) throws -> Void = { channel in
            let configuration = SSHClientConfiguration(
                userAuthDelegate: authDelegate,
                serverAuthDelegate: hostKeyDelegate)
            try channel.pipeline.syncOperations.addHandlers([
                NIOSSHHandler(
                    role: .client(configuration),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, type in router.initialize(channel: child, type: type) }),
                HandshakeHandler(promise: authenticated),
            ])
        }

        let channel: Channel
        do {
            if let via {
                channel = try await via.openTunnelChannel(targetHost: host, targetPort: port) { child in
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                    try addSSHHandlers(child)
                }
            } else if let proxy {
                channel = try await connectThroughProxy(proxy, to: host, port: port, timeout: connectTimeout, loop: loop, authenticated: authenticated, addSSHHandlers: addSSHHandlers)
            } else {
                channel = try await ClientBootstrap(group: loop)
                    .connectTimeout(connectTimeout)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture { try addSSHHandlers(channel) }
                    }
                    .connect(host: host, port: port)
                    .get()
            }
        } catch {
            authenticated.fail(error)
            throw SSHClientError.connectionFailed(describe(error))
        }

        do {
            try await authenticated.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw mapHandshakeError(error)
        }

        return SSHConnection(host: host, port: port, hostKey: hostKeyDelegate.presentedKey, channel: channel, via: via, forwardedChannels: router)
    }

    private static func connectThroughProxy(
        _ proxy: ProxySettings,
        to host: String,
        port: Int,
        timeout: TimeAmount,
        loop: any EventLoop,
        authenticated: EventLoopPromise<Void>,
        addSSHHandlers: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Channel {
        let tunnel = loop.makePromise(of: Void.self)
        let credentials: (String, String)? = proxy.username.flatMap { user in proxy.password.map { (user, $0) } }
        let channel = try await ClientBootstrap(group: loop)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Once the tunnel is up the SSH handlers go in behind the proxy
                    // handler, which then removes itself and replays any bytes that
                    // arrived with the proxy's reply.
                    tunnel.futureResult.whenSuccess {
                        do {
                            try addSSHHandlers(channel)
                        } catch {
                            authenticated.fail(error)
                            channel.close(promise: nil)
                        }
                    }
                    switch proxy.kind {
                    case .http:
                        try channel.pipeline.syncOperations.addHandler(
                            HTTPConnectHandler(targetHost: host, targetPort: port, credentials: credentials, established: tunnel))
                    case .socks5:
                        try channel.pipeline.syncOperations.addHandler(
                            SOCKS5ClientHandler(targetHost: host, targetPort: port, credentials: credentials, established: tunnel))
                    }
                }
            }
            .connect(host: proxy.host, port: proxy.port)
            .get()
        let deadline = loop.scheduleTask(in: timeout) {
            tunnel.fail(SSHClientError.connectionFailed("the proxy \(proxy.host):\(proxy.port) did not open the tunnel within \(timeout.nanoseconds / 1_000_000_000) seconds"))
        }
        do {
            try await tunnel.futureResult.get()
            deadline.cancel()
        } catch {
            deadline.cancel()
            channel.close(promise: nil)
            throw error
        }
        return channel
    }

    // MARK: - Channels

    /// Opens a child channel of `type` on the connection's event loop and runs
    /// `initializer` in it before it is returned.
    func openChannel(type: SSHChannelType, initializer: @escaping @Sendable (Channel) throws -> Void) async throws -> Channel {
        let parent = channel
        let childFuture: EventLoopFuture<Channel> = parent.eventLoop.flatSubmit {
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(promise, channelType: type) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.eventLoop.makeCompletedFuture { try initializer(child) }
                    }
                }
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }
        do {
            return try await childFuture.get()
        } catch {
            throw SSHClientError.channelFailed(Self.describe(error))
        }
    }

    /// A direct-tcpip channel to `targetHost:targetPort` as seen from the
    /// server, carrying raw bytes (the SSH framing is stripped by a codec).
    /// `initializer` adds the handlers that consume the bytes.
    public func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        originator: SocketAddress? = nil,
        initializer: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Channel {
        let origin = originator ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0)) ?? (try! SocketAddress(unixDomainSocketPath: "/"))
        return try await openChannel(type: .directTCPIP(.init(targetHost: targetHost, targetPort: targetPort, originatorAddress: origin))) { child in
            try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
            try initializer(child)
        }
    }

    /// A direct-tcpip channel without the codec, for the jump-host path (the
    /// codec is added inside `initializer` so the SSH handler can follow it).
    private func openTunnelChannel(targetHost: String, targetPort: Int, initializer: @escaping @Sendable (Channel) throws -> Void) async throws -> Channel {
        let origin = (try? SocketAddress(ipAddress: "127.0.0.1", port: 0)) ?? (try! SocketAddress(unixDomainSocketPath: "/"))
        return try await openChannel(type: .directTCPIP(.init(targetHost: targetHost, targetPort: targetPort, originatorAddress: origin)), initializer: initializer)
    }

    /// Starts a subsystem (such as `sftp`) on a session channel. The channel
    /// carries raw bytes; `initializer` adds the handlers.
    public func openSubsystem(_ name: String, initializer: @escaping @Sendable (Channel) throws -> Void) async throws -> Channel {
        let child = try await openChannel(type: .session) { child in
            try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
            try initializer(child)
        }
        do {
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true)).get()
        } catch {
            child.close(promise: nil)
            throw SSHClientError.channelFailed("the server refused the \(name) subsystem: \(Self.describe(error))")
        }
        return child
    }

    /// Asks the server to listen on `bindAddress:port` and send accepted
    /// connections back (remote port forwarding). Returns the port actually
    /// bound (useful when `port` is 0). Register a handler with
    /// `forwardedChannels` first so the connections have somewhere to go.
    public func requestRemoteForward(bindAddress: String, port: Int) async throws -> Int {
        let parent = channel
        let future: EventLoopFuture<GlobalRequest.TCPForwardingResponse?> = parent.eventLoop.flatSubmit {
            let promise = parent.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            do {
                let sshHandler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.sendTCPForwardingRequest(.listen(host: bindAddress, port: port), promise: promise)
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }
        do {
            let response = try await future.get()
            return response?.boundPort ?? port
        } catch {
            throw SSHClientError.channelFailed("the server refused to listen on \(bindAddress):\(port): \(Self.describe(error))")
        }
    }

    public func cancelRemoteForward(bindAddress: String, port: Int) async {
        let parent = channel
        let future: EventLoopFuture<GlobalRequest.TCPForwardingResponse?> = parent.eventLoop.flatSubmit {
            let promise = parent.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            do {
                let sshHandler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.sendTCPForwardingRequest(.cancel(host: bindAddress, port: port), promise: promise)
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }
        _ = try? await future.get()
    }

    /// Opens a session channel with a PTY and an interactive shell.
    ///
    /// `onOutput` and `onClose` are called on the connection's event loop.
    public func openShell(
        term: String = "xterm-256color",
        cols: Int,
        rows: Int,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        onClose: @escaping @Sendable (ShellCloseReason) -> Void
    ) async throws -> SSHShellSession {
        let child = try await openChannel(type: .session) { child in
            try child.pipeline.syncOperations.addHandler(ShellChannelHandler(onOutput: onOutput, onClose: onClose))
        }

        do {
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: term,
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:]))).get()
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)).get()
            }
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
        } catch {
            child.close(promise: nil)
            throw SSHClientError.channelFailed(Self.describe(error))
        }

        return SSHShellSession(channel: child)
    }

    /// Runs one command without a PTY and collects its output.
    ///
    /// `stdin` is written to the command and then closed. Output is capped at
    /// `outputLimit` bytes per stream.
    public func run(
        _ command: String,
        stdin: [UInt8] = [],
        environment: [String: String] = [:],
        outputLimit: Int = 4 * 1024 * 1024,
        timeout: TimeAmount = .seconds(120)
    ) async throws -> CommandResult {
        let resultPromise = channel.eventLoop.makePromise(of: CommandResult.self)
        let child: Channel
        do {
            child = try await openChannel(type: .session) { child in
                try child.pipeline.syncOperations.addHandler(ExecChannelHandler(promise: resultPromise, outputLimit: outputLimit))
            }
        } catch {
            resultPromise.fail(error)
            throw error
        }

        do {
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)).get()
            }
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
            if !stdin.isEmpty {
                var buffer = child.allocator.buffer(capacity: stdin.count)
                buffer.writeBytes(stdin)
                try await child.writeAndFlush(buffer).get()
            }
            try await child.close(mode: .output).get()
        } catch {
            child.close(promise: nil)
            throw SSHClientError.channelFailed(Self.describe(error))
        }

        let deadline = child.eventLoop.scheduleTask(in: timeout) {
            child.close(promise: nil)
            resultPromise.fail(SSHClientError.channelFailed("the command did not finish within \(timeout.nanoseconds / 1_000_000_000) seconds"))
        }
        defer { deadline.cancel() }
        // Cancelling the calling task closes the channel, which ends the remote
        // command (the server sends SIGHUP to it) and fails the result.
        return try await withTaskCancellationHandler {
            do {
                return try await resultPromise.futureResult.get()
            } catch let error as SSHClientError {
                throw error
            } catch {
                throw SSHClientError.channelFailed(Self.describe(error))
            }
        } onCancel: {
            child.eventLoop.execute {
                resultPromise.fail(SSHClientError.cancelled)
                child.close(promise: nil)
            }
        }
    }

    /// Closes the connection and every channel on it. The jump host, if any, stays open.
    public func close() {
        channel.close(promise: nil)
    }

    /// Closes this connection and every bastion it goes through.
    public func closeChain() {
        close()
        via?.closeChain()
    }

    /// Resolves once the underlying channel has closed.
    public func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }

    // MARK: - Error mapping

    private static func mapHandshakeError(_ error: Error) -> SSHClientError {
        if let clientError = error as? SSHClientError {
            return clientError
        }
        return .connectionFailed(describe(error))
    }

    static func describe(_ error: Error) -> String {
        if let clientError = error as? SSHClientError {
            return clientError.errorDescription ?? String(describing: clientError)
        }
        if let proxyError = error as? ProxyError {
            return proxyError.errorDescription ?? String(describing: proxyError)
        }
        if let connectionError = error as? NIOConnectionError {
            if let dnsError = connectionError.dnsAAAAError ?? connectionError.dnsAError {
                return "could not resolve \(connectionError.host): \(dnsError)"
            }
            if let last = connectionError.connectionErrors.last {
                return describe(last.error)
            }
            return "could not connect to \(connectionError.host):\(connectionError.port)"
        }
        if let ioError = error as? IOError {
            return ioError.description
        }
        if let sshError = error as? NIOSSHError {
            return "SSH protocol error: \(sshError)"
        }
        return String(describing: error)
    }
}
