import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// Supplies the SSH connection to use for the next forwarded connection.
/// Returns nil while the host is disconnected; the forwarder then refuses
/// the incoming connection and keeps listening.
public typealias SSHConnectionProvider = @Sendable () -> SSHConnection?

/// Local port forwarding: listens on the Mac and sends each accepted
/// connection to `targetHost:targetPort` through a direct-tcpip channel of
/// whatever connection `provider` returns at that moment, so the listener
/// survives reconnects.
public final class LocalForwardListener: @unchecked Sendable {
    public let bindAddress: String
    public let requestedPort: Int
    public let targetHost: String
    public let targetPort: Int
    public let counters = ForwardCounters()

    private let provider: SSHConnectionProvider
    private let serverChannel = Mutex<Channel?>(nil)

    public init(bindAddress: String, port: Int, targetHost: String, targetPort: Int, provider: @escaping SSHConnectionProvider) {
        self.bindAddress = bindAddress
        self.requestedPort = port
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.provider = provider
    }

    public var boundPort: Int? { serverChannel.withLock { $0?.localAddress?.port } }
    public var isListening: Bool { serverChannel.withLock { $0?.isActive ?? false } }

    /// Binds the listener and returns the port (useful when 0 was requested).
    @discardableResult
    public func start(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> Int {
        let provider = self.provider
        let counters = self.counters
        let target = (targetHost, targetPort)
        let channel: Channel
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            LocalForwardAcceptHandler(targetHost: target.0, targetPort: target.1, provider: provider, counters: counters))
                    }
                }
                .bind(host: bindAddress, port: requestedPort)
                .get()
        } catch {
            throw SSHClientError.channelFailed("could not listen on \(bindAddress):\(requestedPort): \(SSHConnection.describe(error))")
        }
        serverChannel.withLock { $0 = channel }
        return channel.localAddress?.port ?? requestedPort
    }

    public func stop() async {
        let channel = serverChannel.withLock { channel -> Channel? in
            let current = channel
            channel = nil
            return current
        }
        guard let channel else { return }
        try? await channel.close().get()
    }
}

/// Sits in a freshly accepted local socket until its SSH channel is open,
/// then glues the two together and leaves the pipeline.
final class LocalForwardAcceptHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let targetHost: String
    private let targetPort: Int
    private let provider: SSHConnectionProvider
    private let counters: ForwardCounters

    init(targetHost: String, targetPort: Int, provider: @escaping SSHConnectionProvider, counters: ForwardCounters) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.provider = provider
        self.counters = counters
    }

    func channelActive(context: ChannelHandlerContext) {
        let local = context.channel
        counters.connectionOpened()
        let counters = self.counters
        local.closeFuture.whenComplete { _ in counters.connectionClosed() }
        guard let connection = provider(), connection.isActive else {
            counters.setError("Not connected to the host; the connection was refused.")
            local.close(promise: nil)
            return
        }
        ForwardGlue.connect(local: local, through: connection, to: targetHost, port: targetPort, counters: counters, acceptHandler: self)
        context.fireChannelActive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Shared plumbing: opens the direct-tcpip channel, installs a glue pair, and
/// starts reading on the local socket.
enum ForwardGlue {
    static func connect(local: Channel, through connection: SSHConnection, to host: String, port: Int, counters: ForwardCounters, acceptHandler: (any RemovableChannelHandler)?, replay: ByteBuffer? = nil) {
        let (localGlue, remoteGlue) = GlueHandler.matchedPair(
            firstBytes: { counters.addSent($0) },
            secondBytes: { counters.addReceived($0) })
        let originator = local.remoteAddress
        Task {
            do {
                let remote = try await connection.openDirectTCPIP(targetHost: host, targetPort: port, originator: originator) { child in
                    try child.pipeline.syncOperations.addHandler(remoteGlue)
                }
                local.eventLoop.execute {
                    guard local.isActive else {
                        remote.close(promise: nil)
                        return
                    }
                    do {
                        try local.pipeline.syncOperations.addHandler(localGlue)
                        if let acceptHandler {
                            local.pipeline.syncOperations.removeHandler(acceptHandler, promise: nil)
                        }
                    } catch {
                        local.close(promise: nil)
                        remote.close(promise: nil)
                        return
                    }
                    if let replay, replay.readableBytes > 0 {
                        counters.addSent(replay.readableBytes)
                        remote.writeAndFlush(replay, promise: nil)
                    }
                    local.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in local.read() }
                }
            } catch {
                counters.setError("Could not reach \(host):\(port) through the host: \(error.localizedDescription)")
                local.close(promise: nil)
            }
        }
    }
}
