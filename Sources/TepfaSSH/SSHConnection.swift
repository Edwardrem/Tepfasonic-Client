import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// An authenticated SSH connection. Create one with `connect`, then open
/// shells on it. Closing the connection closes every channel.
public final class SSHConnection: @unchecked Sendable {
    public let host: String
    public let port: Int
    /// The host key the server presented.
    public let hostKey: HostKeyInfo?

    let channel: Channel

    private init(host: String, port: Int, hostKey: HostKeyInfo?, channel: Channel) {
        self.host = host
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
    }

    public var isActive: Bool { channel.isActive }

    /// Connects, verifies the host key through `hostKeyVerifier`, and authenticates.
    public static func connect(
        host: String,
        port: Int = 22,
        credentials: SSHCredentials,
        hostKeyVerifier: any HostKeyVerifier,
        connectTimeout: TimeAmount = .seconds(15),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> SSHConnection {
        let loop = group.next()
        let authenticated = loop.makePromise(of: Void.self)
        let authDelegate = ClientAuthDelegate(credentials: credentials)
        let hostKeyDelegate = HostKeyDelegate(host: host, port: port, verifier: hostKeyVerifier)

        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(connectTimeout)
            .channelInitializer { channel in
                let configuration = SSHClientConfiguration(
                    userAuthDelegate: authDelegate,
                    serverAuthDelegate: hostKeyDelegate)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        HandshakeHandler(promise: authenticated),
                    ])
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
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

        return SSHConnection(host: host, port: port, hostKey: hostKeyDelegate.presentedKey, channel: channel)
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
        let parent = channel
        let childFuture: EventLoopFuture<Channel> = parent.eventLoop.flatSubmit {
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(promise, channelType: .session) { child, channelType in
                    guard channelType == .session else {
                        return child.eventLoop.makeFailedFuture(SSHClientError.channelFailed("unexpected channel type"))
                    }
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ShellChannelHandler(onOutput: onOutput, onClose: onClose))
                        }
                    }
                }
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }

        let child: Channel
        do {
            child = try await childFuture.get()
        } catch {
            throw SSHClientError.channelFailed(Self.describe(error))
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
        let parent = channel
        let resultPromise = parent.eventLoop.makePromise(of: CommandResult.self)
        let childFuture: EventLoopFuture<Channel> = parent.eventLoop.flatSubmit {
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(promise, channelType: .session) { child, channelType in
                    guard channelType == .session else {
                        return child.eventLoop.makeFailedFuture(SSHClientError.channelFailed("unexpected channel type"))
                    }
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ExecChannelHandler(promise: resultPromise, outputLimit: outputLimit))
                        }
                    }
                }
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }

        let child: Channel
        do {
            child = try await childFuture.get()
        } catch {
            resultPromise.fail(error)
            throw SSHClientError.channelFailed(Self.describe(error))
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

    /// Closes the connection and every channel on it.
    public func close() {
        channel.close(promise: nil)
    }

    /// Resolves once the underlying TCP connection has closed.
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
